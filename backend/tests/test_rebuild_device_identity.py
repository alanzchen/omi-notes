"""C1-01 (Carbon IT1, 2026-11-25): one rule for a capture's device during a rebuild. The device is the id recorded for
the capture (capture.json's device_id, else its first readable chunk or tombstone header). Every chunk and tombstone
header must name exactly that id, in the vault's folder for it (safe_component, compared case-insensitively: APFS folds
case). The rebuild writes that id, never the folder name, into every row, and a capture whose rebuilt device differs
from the previous index's is refused like a missing upload. Built from Carbon's reproducers (which pinned the defects)."""

from __future__ import annotations

import hashlib
import uuid
from pathlib import Path

import pytest

from omi_notes.envelope import build_envelope, parse_envelope
from omi_notes.ingest import index_chunk
from omi_notes.rebuild import StartupIncomplete, open_index
from omi_notes.settings import Settings
from omi_notes.vault import Vault

from .test_disk_full import _envs


def _settings(root: Path) -> Settings:
    return Settings(vault_dir=root / "vault", index_dir=root / "index", lock_dir=root / "locks",
                    omi_notes_token="test-token", stt_provider="fake", llm_provider="fake")  # fmt: skip


def _tombstoned(tmp_path, device: str, *, capture_json: bool = True, header_device: str | None = None):
    """An acknowledged, tombstoned chunk of `device` (its index row and receipt), optionally with capture.json evidence,
    whose tombstone header names `header_device` (default: the same device)."""
    s = _settings(tmp_path)
    v = Vault.open(s)
    db = open_index(s, v)
    cap = str(uuid.uuid4())
    env = parse_envelope(_envs(cap)[0])
    header = dict(env.header.model_dump(mode="json"), device_id=device)
    raw = build_envelope(header, env.payload)
    digest = hashlib.sha256(raw).hexdigest()
    v.append_confirmed(v.receipts_path(device, cap), {"seq": 0, "sha256": digest, "received_at": 100.0})
    with db.tx() as conn:
        index_chunk(conn, parse_envelope(raw).header, digest=digest, size=len(raw),
                    path=v.relpath(v.chunk_path(device, cap, 0)), received_at=100.0, raw_deleted=True)  # fmt: skip
    if capture_json:
        v.write_json(v.capture_json_path(device, cap), {
            "capture_id": cap, "device_id": device, "finalized": False,
            "deleted": {"0": {"audio_start": 10.0, "audio_end": 20.0, "runs": [], "stats": {}, "carry": None}},
            "coverage": [[0, "live", 10.0, 20.0]], "losses": [], "ring_seen": [], "ring_records": [],
            "speech_open": [[0, 12.0, 18.0]]})  # fmt: skip
    v.write_json(v.tombstone_path(device, cap, 0), {"sha256": digest, "size": len(raw),
                                                    "header": dict(header, device_id=header_device or device),
                                                    "deleted_at": 1})  # fmt: skip
    db.close()
    return s, v, cap


def test_the_evidence_rows_carry_the_recorded_device_not_the_folder_name(tmp_path):
    s, v, cap = _tombstoned(tmp_path, "Watch:example")
    db = open_index(s, v, force_rebuild=True)
    for table in ("chunks", "coverage", "speech"):
        assert db.one(f"SELECT device_id FROM {table} WHERE capture_id=?", (cap,))["device_id"] == "Watch:example", table
    db.close()


@pytest.mark.parametrize("capture_json", [True, False])
def test_a_header_naming_another_device_with_the_same_folder_is_refused(tmp_path, capture_json):
    """safe_component isn't one-to-one: "Watch/example" and "Watch:example" share a folder."""
    s, v, cap = _tombstoned(tmp_path, "Watch:example", capture_json=capture_json, header_device="Watch/example")
    with pytest.raises(StartupIncomplete, match="missing"):
        open_index(s, v, force_rebuild=True)


def _case_folding(tmp_path) -> bool:
    probe = tmp_path / "case_probe"
    probe.mkdir()
    return (tmp_path / "CASE_PROBE").exists()


@pytest.mark.parametrize("kind", ["tombstone", "chunk"])
def test_an_id_differing_only_by_case_from_its_folder_rebuilds_on_a_case_folding_disk(tmp_path, kind):
    """On case-insensitive APFS a later capture of the lowercase id lands in the folder an uppercase id created."""
    if not _case_folding(tmp_path):
        pytest.skip("filesystem is case-sensitive")
    s = _settings(tmp_path)
    v = Vault.open(s)
    db = open_index(s, v)
    upper = "5EED0000-0000-4000-8000-00000000C0DE"
    lower = upper.lower()
    cap1, cap2 = str(uuid.uuid4()), str(uuid.uuid4())
    e1, e2 = parse_envelope(_envs(cap1)[0]), parse_envelope(_envs(cap2)[0])
    raw1 = build_envelope(dict(e1.header.model_dump(mode="json"), device_id=upper), e1.payload)
    h2 = dict(e2.header.model_dump(mode="json"), device_id=lower)
    raw2 = build_envelope(h2, e2.payload)
    d1, d2 = hashlib.sha256(raw1).hexdigest(), hashlib.sha256(raw2).hexdigest()
    v.publish_bytes(v.chunk_path(upper, cap1, 0), raw1)
    v.append_confirmed(v.receipts_path(upper, cap1), {"seq": 0, "sha256": d1, "received_at": 100.0})
    if kind == "tombstone":
        v.write_json(v.tombstone_path(lower, cap2, 0), {"sha256": d2, "size": len(raw2), "header": h2, "deleted_at": 1})
    else:
        v.publish_bytes(v.chunk_path(lower, cap2, 0), raw2)
    v.append_confirmed(v.receipts_path(lower, cap2), {"seq": 0, "sha256": d2, "received_at": 101.0})
    with db.tx() as conn:
        index_chunk(conn, parse_envelope(raw1).header, digest=d1, size=len(raw1),
                    path=v.relpath(v.chunk_path(upper, cap1, 0)), received_at=100.0)  # fmt: skip
        index_chunk(conn, parse_envelope(raw2).header, digest=d2, size=len(raw2),
                    path=v.relpath(v.chunk_path(lower, cap2, 0)), received_at=101.0, raw_deleted=kind == "tombstone")  # fmt: skip
    db.close()
    again = open_index(s, v, force_rebuild=True)
    assert again.one("SELECT device_id FROM chunks WHERE capture_id=?", (cap2,))["device_id"] == lower
    assert again.one("SELECT device_id FROM chunks WHERE capture_id=?", (cap1,))["device_id"] == upper
    again.close()
