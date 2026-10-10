"""The owner's explicit priority for a conversation: "important", "less_useful", or back to "auto".

It lives in the vault, `<conversation dir>/priority.json` (written atomically), so it survives index
rebuilds, re-renders and re-summaries, and the model never overwrites it. It changes nothing else:
not the note, its path, keep/discard, statistics or the audio. Requests are deduplicated by
`request_id`, and the later choice wins by when the owner made it (`set_at`), so a delayed old
request (or an old "restore") can't undo a newer choice.

Each stored choice records where it came from (`source`): "app" for the owner's choice in the app,
"pendant" for a double tap set to star the conversation (button event code 3, applied by the worker
once the conversation is finished, with its `event_id`).
"""

from __future__ import annotations

from datetime import UTC, datetime

from .ingest import ApiError
from .lock import SpeakerLock
from .util import iso_utc_epoch
from .vault import Vault
from .views import LISTED

STATES = ("important", "less_useful", "auto")
REQUEST_MEMORY = 50


def _path(pipeline, conv_id: str):
    return pipeline.conv_dir(conv_id) / "priority.json"


def read(pipeline, conv_id: str) -> dict | None:
    """The stored choice, None when the owner never chose (or the file is unreadable)."""
    try:
        data = Vault.read_json(_path(pipeline, conv_id))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("state") not in STATES:
        return None
    return data


def view(data: dict | None, *, applied: bool | None = None) -> dict:
    out = {"state": (data or {}).get("state", "auto"), "revision": (data or {}).get("revision", 0),
           "set_at": iso_utc_epoch(data["set_at"]) if data and data.get("set_at") else None}  # fmt: skip
    if data and data.get("source"):
        out["source"] = data["source"]
    return out if applied is None else out | {"applied": applied}


def put(pipeline, conv_id: str, body: dict) -> dict:
    state, request_id, set_at = body.get("state"), body.get("request_id"), body.get("set_at")
    if state not in STATES:
        raise ApiError(422, "invalid_body", "state must be important, less_useful or auto")
    if not isinstance(request_id, str) or not request_id or len(request_id) > 100:
        raise ApiError(422, "invalid_body", "request_id is required")
    try:
        when = datetime.fromisoformat(str(set_at).replace("Z", "+00:00"))
        if when.tzinfo is None:
            raise ValueError
    except ValueError as exc:
        raise ApiError(422, "invalid_body", "set_at must be an ISO-8601 time with a timezone") from exc
    when_epoch = when.astimezone(UTC).timestamp()
    row = pipeline.db.one(f"SELECT status FROM conversations WHERE id=? AND {LISTED}", (conv_id,))
    if row is None:
        raise ApiError(404, "not_found", "unknown conversation")
    if row["status"] == "open":
        raise ApiError(409, "in_progress", "the conversation is still being recorded")
    return _store(pipeline, conv_id, state, when_epoch, request_id, source="app")


def from_pendant(pipeline, conv_id: str, state: str, *, set_at: float, event_id: str) -> dict:
    """A star (or un-star) from the pendant's double tap, for a finished conversation. Same rules as
    the app's choice: deduplicated (by the event), and the later of the two wins."""
    return _store(pipeline, conv_id, state, set_at, f"pendant:{event_id}", source="pendant", event_id=event_id)


def _store(pipeline, conv_id: str, state: str, when_epoch: float, request_id: str, *, source: str,
           event_id: str | None = None) -> dict:  # fmt: skip
    with SpeakerLock(pipeline.vault, name="priority.lock"):
        current = read(pipeline, conv_id) or {"format": 1, "state": "auto", "revision": 0, "set_at": 0, "requests": []}
        if request_id in current.get("requests", []):
            return view(current, applied=True)  # a repeat of a request already applied
        if when_epoch <= float(current.get("set_at") or 0):
            return view(current, applied=False)  # an older choice than the stored one: the newer stands
        data = {"format": 1, "state": state, "set_at": when_epoch, "revision": int(current.get("revision", 0)) + 1,
                "request_id": request_id, "requests": (list(current.get("requests", [])) + [request_id])[-REQUEST_MEMORY:],
                "source": source}  # fmt: skip
        if event_id:
            data["event_id"] = event_id
        Vault.write_json(_path(pipeline, conv_id), data)
        return view(data, applied=True)
