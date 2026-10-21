"""Small shared helpers."""

from __future__ import annotations

import hashlib
import json
import re
import uuid
from datetime import UTC, datetime

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def iso_utc_epoch(epoch: float) -> str:
    """ISO-8601 UTC with milliseconds and `Z`, as the wire contract uses."""
    dt = datetime.fromtimestamp(epoch, UTC)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def uuid7_for(epoch: float, key: str) -> str:
    """A deterministic UUIDv7: its time is `epoch`, its random bits come from sha256(key). The same
    decision made again (after an index rebuild) gets the same id."""
    ms = int(round(epoch * 1000)) & ((1 << 48) - 1)
    rand = int.from_bytes(hashlib.sha256(key.encode()).digest()[:10], "big")
    rand_a = (rand >> 62) & 0xFFF
    rand_b = rand & ((1 << 62) - 1)
    value = (ms << 80) | (0x7 << 76) | (rand_a << 64) | (0b10 << 62) | rand_b
    return str(uuid.UUID(int=value))
