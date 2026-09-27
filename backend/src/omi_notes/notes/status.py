"""`_status.md`: devices, captures, queue and errors at a glance.

Deliberately contains no "rendered at" timestamp so it is only rewritten when something changes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from zoneinfo import ZoneInfo


@dataclass
class StatusSnapshot:
    server_version: str
    stt: str
    llm: str
    vad: str
    vad_warning: str | None
    devices: list[dict] = field(default_factory=list)
    open_captures: list[dict] = field(default_factory=list)
    pending_ring: list[str] = field(default_factory=list)
    open_conversations: list[dict] = field(default_factory=list)
    queue: dict = field(default_factory=dict)
    failed_conversations: list[dict] = field(default_factory=list)
    attention: list[dict] = field(default_factory=list)  # finished notes that could not be updated
    failed_chunks: list[dict] = field(default_factory=list)
    edited: list[dict] = field(default_factory=list)  # notes edited outside My Notes (re-render postponed)
    conflict_copies: list[str] = field(default_factory=list)  # "<path> (copy of <note>)"
    read_only: str | None = None  # the vault is not written (incomplete sync, divergence, lost lease)
    replaying: bool = False


def _t(epoch: float | None, tz: ZoneInfo) -> str:
    return datetime.fromtimestamp(epoch, tz).strftime("%Y-%m-%d %H:%M") if epoch else "—"


def render_status(s: StatusSnapshot, tz: ZoneInfo) -> str:
    out = ["# Omi Notes status", ""]
    if s.read_only:
        out += [f"> [!danger] Not writing to this vault: {s.read_only}", ""]
    if s.replaying:
        out += ["> [!info] Rebuilding the index: raw audio is being replayed before new notes are made.", ""]
    if s.vad_warning:
        out += [f"> [!danger] {s.vad_warning}", ""]
    diarization = [c for c in s.failed_conversations if c.get("error_kind") == "diarization"]
    if diarization:
        out += [f"> [!danger] {diarization[0].get('error') or 'Transcripts have no speaker labels.'}", ""]
    auth = [c for c in s.failed_conversations if c.get("error_kind") in ("auth", "billing", "config")]
    if auth:
        out += [
            "> [!danger] A provider rejected our credentials or billing. Fix the key/account, then run "
            "`omi-notes retry-failed`.",
            "",
        ]
    out += [
        f"- Server {s.server_version} · STT {s.stt} · LLM {s.llm} · VAD {s.vad}",
        f"- Queue: {s.queue.get('chunks_pending', 0)} chunks pending, {s.queue.get('conversations_open', 0)} open, "
        f"{s.queue.get('conversations_pending', 0)} processing, {s.queue.get('failed', 0)} failed",
        "",
        "## Devices",
        "",
    ]
    if not s.devices:
        out += ["_No device has uploaded anything yet._", ""]
    for d in s.devices:
        hb = d.get("heartbeat") or {}
        name = " · ".join(x for x in (d.get("model_number") or d.get("device_name"), d.get("firmware_revision")) if x)
        out.append(f"### {name or 'Omi device'} (`{d['device_id'][:8]}`)")
        out.append("")
        out.append(f"- Last seen: {_t(d.get('last_seen'), tz)}")
        if "battery" in hb:
            out.append(f"- Battery: {hb['battery']}%" + (" (charging)" if hb.get("charging") else ""))
        if "app_state" in hb:
            outbox = f", outbox {hb['outbox_chunks']} chunks" if "outbox_chunks" in hb else ""
            out.append(f"- App: {hb['app_state']}{outbox}")
        if hb.get("rtc_valid") is False:
            out.append("- ⚠️ Device clock not set: offline recording is disabled until the phone syncs time")
        if "offline_unread" in hb:
            out.append(f"- Offline records waiting on the device: {hb['offline_unread']}")
        out.append("")
    if s.open_captures:
        out += ["## Live captures", ""]
        out += [f"- `{c['capture_id'][:8]}` since {_t(c['started'], tz)}, {c['chunks']} chunks" for c in s.open_captures]
        out.append("")
    if s.pending_ring:
        out += ["## Waiting for offline sync", ""]
        out += [f"- {line}" for line in s.pending_ring]
        out.append("")
    if s.open_conversations:
        out += ["## Open conversations", ""]
        for c in s.open_conversations:
            out.append(f"- Started {_t(c['start'], tz)}, last speech {_t(c['end'], tz)}"
                       + (f" — waiting for {c['waiting_for']}" if c.get("waiting_for") else ""))  # fmt: skip
        out.append("")
    if s.failed_conversations:
        out += ["## Failed conversations", ""]
        for c in s.failed_conversations:
            out.append(f"- {_t(c['start'], tz)} `{c['id'][:8]}` ({c.get('failed_stage') or '?'}): {c.get('error') or ''}")
        out += ["", "Run `omi-notes retry-failed` after fixing the cause.", ""]
    if s.attention:
        out += ["## Notes that could not be updated", ""]
        for c in s.attention:
            out.append(f"- {_t(c['start'], tz)} `{c['id'][:8]}` {c.get('note_path') or ''}: {c.get('error') or ''}")
        out += ["", "The note was left untouched; it is retried automatically (for My Notes problems, fix the markers).", ""]
    if s.edited:
        out += ["## Notes edited outside My Notes", ""]
        for c in s.edited:
            out.append(f"- {_t(c['start'], tz)} [[{c['note_path'][:-3]}]] (`{c['id'][:8]}`)")
        out += [
            "",
            "These notes changed outside their My Notes section, so updates to them are postponed. Choose one:",
            "- keep the server's version: `omi-notes note overwrite <id>` (your version is saved to `_omi/displaced/`)",
            "- keep yours for good: `omi-notes note freeze <id>` (the server stops updating that note)",
            "",
        ]
    if s.conflict_copies:
        out += ["## Conflicting copies", ""]
        out += [f"- {line}" for line in s.conflict_copies]
        out += ["", "A sync tool made these copies; they are left alone. Delete the ones you don't need.", ""]
    if s.failed_chunks:
        out += ["## Failed chunks", ""]
        out += [f"- `{c['capture_id'][:8]}` #{c['chunk_sequence']}: {c.get('error') or ''}" for c in s.failed_chunks]
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"
