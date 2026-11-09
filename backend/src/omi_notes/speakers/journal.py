"""Durable multi-file sample operations: write the intent, apply, then complete (docs/speaker-learning.md,
"Voices hub").

A move, a reject that also corrects its label, an enrollment-import merge, and the undo of a move or reject
each change several vault files (sample files of two people, a conversation's `speakers.json`, an import
result). Each is one journaled operation:

1. its intent is written atomically to `_omi/speakers/journal/<op id>.json` (everything needed to finish it,
   ids chosen up front), after its preconditions were checked under the speaker lock;
2. its steps are applied in an order where every intermediate state is safe, each step idempotent: a copy a
   move or merge writes carries `pending_op` and is ineligible (`store.sample_eligible`) until the operation
   completes; an undo first makes the copy pending again, then restores the original, then removes the copy;
3. it completes by deleting the intent file.

`reconcile` rolls every incomplete operation forward. It runs before every model build (`SpeakerStore.reconcile`,
from `samples`), before every sample decision, before forget, and at worker startup, under the speaker lock.
Steps never depend on anything an interrupted operation could leave half done; a label step applies only while
the label still lists the operation's samples under the person they came from, and is recorded as a request
entry in `speakers.json` (so it is applied once and undone by `POST /v1/speakers/undo`).
"""

from __future__ import annotations

import logging
import threading
import time
import uuid

from ..ingest import ApiError
from ..notes.writer import remove
from ..spool import fsync_dir
from ..vault import Vault
from .store import consent_ok
from .voices import decode_vector

log = logging.getLogger(__name__)

_busy = threading.local()  # an operation being applied in this thread: don't reconcile into it

PROVENANCE = ("clips", "voices_file", "audio_sha", "caption", "f0", "f0_voiced", "f0_source", "f0_estimator", "f0_clips",
              "f0_aggregation", "f0_measured_at", "f0_imported_at", "import", "imported_at")  # fmt: skip


def directory(store):
    return store.vault.speakers / "journal"


def pending(store) -> list[dict]:
    folder = directory(store)
    if not folder.exists():
        return []
    ops = [Vault.read_json(p) for p in sorted(folder.glob("*.json"))]
    return sorted((op for op in ops if op and op.get("id")), key=lambda op: (op.get("at") or 0, op["id"]))


def reconcile(store) -> int:
    """Finish every incomplete operation (roll forward); how many. Cheap when there are none."""
    if getattr(_busy, "op", None) or not pending(store):
        return 0
    done = 0
    with store.lock:
        for op in pending(store):  # read again under the lock
            try:
                apply(store, op)
                done += 1
            except Exception:  # one bad operation must not stop the others (it stays journaled, retried next time)
                log.exception("could not finish the journaled speaker operation %s", op.get("id"))
    return done


def involved(op: dict) -> set[str]:
    """The people whose voice data an operation touches."""
    return {p for p in (op.get("from"), op.get("to"), op.get("person")) if p}


def gaining(op: dict) -> str | None:
    """Whose voice an operation puts (back) into use: they need current consent whenever it is applied."""
    return {"move": op.get("to"), "merge": op.get("person"), "unmove": op.get("from"), "unreject": op.get("person")}.get(op["kind"])


def _samples_of(op: dict) -> set[str]:
    ids = {sid for pair in op.get("pairs") or [] for sid in pair} | set(op.get("samples") or []) | set(op.get("replaced") or [])
    return ids | ({op["sample"]["sample_id"]} if op.get("sample") else set())


def _label_of(op: dict) -> tuple | None:
    where = op.get("label")
    return (where["conversation_id"], where["label"]) if where else None


def blocking(store, persons: set, samples: set = frozenset(), labels: set = frozenset()) -> None:
    """Refuse a change while an operation recovery couldn't finish touches the same people, samples or label (call
    after `reconcile`, under the speaker lock): acting on top of a half-applied operation could be overwritten by it.
    A person whose forget began but didn't finish gets no new voice data either."""
    persons = {p for p in persons if p}
    for op in pending(store):
        if involved(op) & persons or _samples_of(op) & set(samples) or _label_of(op) in set(labels):
            raise ApiError(409, "recovery_pending", "an earlier change to these voices is still being recovered; try again later")
    forgetting(store, persons)


def forgetting(store, persons: set) -> None:
    """Refuse new voice data for a person whose forget is unfinished (`_omi/speakers/forgetting/<id>.json`)."""
    for person_id in persons:
        if person_id and store.forgetting_path(person_id).exists():
            raise ApiError(409, "forget_in_progress", "forgetting this person's voice hasn't finished; finish it first")


def cancel_for(store, person_id: str) -> int:
    """Forget: every operation touching this person is cancelled (rolled back where it changed someone else) and its
    intent, which may hold the voice, is deleted. Raises if any can't be: forget must not proceed past it."""
    n = 0
    for op in pending(store):
        if person_id in involved(op):
            if op.get("phase") == "committed":
                apply(store, op)  # past its point of no return: finished (writes nothing for the forgotten person)
            else:
                cancel(store, op, forgotten={person_id})
            n += 1
    return n


def commit_point(store, op: dict) -> None:
    """Record that `op` is past its point of no return: from here a replay always finishes it (rolls forward)."""
    if op.get("phase") != "committed":
        op["phase"] = "committed"
        Vault.write_json(directory(store) / f"{op['id']}.json", op)


def run(store, op: dict) -> dict:
    """Journal `op` and apply it (call under the speaker lock, after checking its preconditions)."""
    op = {"id": str(uuid.uuid4()), "at": time.time()} | op
    # every involved person's forget generation: a replay after any of them was forgotten cancels instead
    op["generations"] = {p: store.forget_count(p) for p in sorted(involved(op))}
    store.vault.raise_format(6)  # pending copies and moved records: an older backend must refuse the vault
    Vault.write_json(directory(store) / f"{op['id']}.json", op)
    apply(store, op)
    return op


def complete(store, op: dict) -> None:
    path = directory(store) / f"{op['id']}.json"
    if remove(path):
        fsync_dir(path.parent)


def _invalid(store, op: dict) -> str:
    """Why replaying this operation now would be wrong ("" when it isn't)."""
    for person_id, generation in (op.get("generations") or {}).items():
        if store.forget_count(person_id) != generation:
            return "a person's voice was forgotten since"
    target = gaining(op)
    if target and not consent_ok(store.person(target), store.settings()):
        return "consent was withdrawn since"
    return ""


def apply(store, op: dict) -> None:
    why = "" if op.get("phase") == "committed" else _invalid(store, op)
    if why:
        log.warning("cancelling the journaled speaker operation %s: %s", op["id"], why)
        cancel(store, op)
        return
    _busy.op = op["id"]
    try:
        {"move": _move, "unmove": _unmove, "reject": _reject, "unreject": _unreject, "merge": _merge}[op["kind"]](store, op)
    finally:
        _busy.op = None
    # the work it leaves is recorded before the operation is complete: voices changed, so assignments re-run
    store.db.set_meta("relabel_pending", "1")
    store.samples_changed()
    complete(store, op)


# -- helpers ------------------------------------------------------------------------------------------


def _set_pending(store, person_id: str, sample_id: str, op_id: str | None) -> None:
    data = store.read_sample(person_id, sample_id)
    if data is None or data.get("pending_op") == op_id:
        return
    data = dict(data)
    if op_id is None:
        data.pop("pending_op", None)
    else:
        data["pending_op"] = op_id
    store._publish_sample(person_id, sample_id, data)


def _label_step(store, op: dict, request_id: str, change) -> None:
    """Apply `change(before) -> (after, record) | None` to the operation's label once (a request entry)."""
    where = op.get("label")
    if not where:
        return
    conv_id, label = where["conversation_id"], where["label"]
    if store.db.one("SELECT 1 FROM conversations WHERE id=?", (conv_id,)) is None:
        return
    store.sync_conversation(conv_id)
    if store.request_result(conv_id, request_id) is not None:
        _schedule_render(store, conv_id)  # the label part was applied; its render may not have been scheduled
        return
    states = store.labels(conv_id)
    made = change(dict(states.get(label) or {}))
    if made is None:
        return  # the label changed since: the samples alone are affected
    after, record = made
    before = states.get(label) or {}
    states[label] = after
    store.write_labels(conv_id, states, request=(request_id, record | {
        "label": label, "before": store.persisted({label: before}).get(label), "after": store.persisted({label: after}).get(label)}))  # fmt: skip
    _schedule_render(store, conv_id)


DECISION_KEYS = ("person_id", "source", "samples", "not")


def _schedule_render(store, conv_id: str) -> None:
    """Its note shows the label's name: re-render it (from cache). Idempotent, so every replay that reaches the step
    schedules it, before the operation completes."""
    store.db.execute("UPDATE conversations SET needs_render=1, next_attempt_at=NULL WHERE id=? AND note_path IS NOT NULL", (conv_id,))


def _restore(store, op: dict):
    """The label step of an undo: put the label back as it was before `undo_of`, only while it is still exactly as
    `undo_of` left it (a newer choice is never overwritten by a replay)."""

    def change(before: dict):
        where = op["label"]
        original = (store.request_result(where["conversation_id"], op["undo_of"]) or {}).get("after") or {}
        current = store.persisted({where["label"]: before}).get(where["label"]) or {}
        # the decision itself (match evidence a relabel refreshes doesn't count)
        if any(current.get(k) != original.get(k) for k in DECISION_KEYS):
            return None
        return op["label_before"], {"undo_of": op["undo_of"]}

    return change


# -- operations ------------------------------------------------------------------------------------


def _move(store, op: dict) -> None:
    a, b, rid = op["from"], op["to"], op["request_id"]
    if store.person(b) is None and not store.person_dir(b).exists():
        return  # forgotten meanwhile: nothing is recreated (the originals stay as they were)
    for src, new in op["pairs"]:  # 1. the copies, pending (never eligible before the originals are marked)
        data = store.read_sample(a, src)
        if data is None:
            continue
        extra = {k: data[k] for k in PROVENANCE if data.get(k) is not None}
        extra |= {"pending_op": op["id"], "moved_from": {"person_id": a, "sample_id": src}}
        person = store.person(b)
        store.add_sample(b, decode_vector(data["vector_b64"]), model=data["model"], model_sha=data["model_sha"], source=data["source"],
                         seconds=data.get("seconds") or 0.0, day=data.get("day"), session=data.get("session"),
                         conversation_id=data.get("conversation_id"), label=data.get("label"), request_id=f"{rid}:move:{src}",
                         enrollment_id=None, now=op["at"], extra=extra, sample_id=new,
                         attested=bool(person and (person["me"] or person["attested_at"])))  # fmt: skip
    for src, new in op["pairs"]:  # 2. the originals are marked moved
        data = store.read_sample(a, src)
        if data is not None and (data.get("moved_to") or {}).get("sample_id") != new and store.read_sample(b, new) is not None:
            store.set_sample_state(a, src, "moved", action="move", by=op.get("by", "user"), request_id=rid, now=op["at"],
                                   extra={"moved_to": {"person_id": b, "sample_id": new}},
                                   record={"op": op["id"]} | ({"label": op["label"]["label"]} if op.get("label") else {}))  # fmt: skip
    sources = {src for src, _ in op["pairs"]}
    copies = {new for src, new in op["pairs"] if store.read_sample(b, new) is not None}

    def rename(before: dict):  # 3. the label follows its samples
        if before.get("person_id") != a or not sources & set(before.get("samples") or []):
            return None
        # every sample the label keeps must be the new person's: the old person's others (removed, moved, or
        # already gone) are detached, and the undo puts them back with the rest of the state
        detached = sorted(set(before.get("samples") or []) - sources)
        after = before | {"person_id": b, "source": "user", "forgotten": False, "samples": sorted(copies),
                          "not": sorted(set(before.get("not") or []) - {b})}  # fmt: skip
        return after, {"person_id": b, "sample": "moved", "keep_unknown": False, "withdrawn": None,
                       "moved": {"person_id": a, "to_person": b, "pairs": op["pairs"], "op": op["id"], "detached": detached}}  # fmt: skip

    _label_step(store, op, rid, rename)
    for _, new in op["pairs"]:  # 4. the copies count
        _set_pending(store, b, new, None)


def _unmove(store, op: dict) -> None:
    a, b, uid = op["from"], op["to"], op["request_id"]
    for _, new in op["pairs"]:  # 1. the copies stop counting first
        _set_pending(store, b, new, op["id"])
    for src, new in op["pairs"]:  # 2. the originals are back
        data = store.read_sample(a, src)
        if data is not None and data.get("state") == "moved" and (data.get("moved_to") or {}).get("sample_id") == new:
            store.update_sample(a, src, {"state": "active", "moved_to": None}, action="undo", by="user", request_id=uid,
                                now=op["at"], record={"undo_of": op["undo_of"], "op": op["id"], "from": "moved", "to": "active"})  # fmt: skip
    _label_step(store, op, f"{uid}:{op['undo_of']}", _restore(store, op))
    commit_point(store, op)  # the originals count again: from here it only rolls forward
    for _, new in op["pairs"]:  # 3. the copies go
        store.remove_sample_ids(b, [new])


def _reject(store, op: dict) -> None:
    x, rid = op["person"], op["request_id"]
    for sid in op["samples"]:
        data = store.read_sample(x, sid)
        if data is not None and (data.get("state") or "active") == "active":
            store.set_sample_state(x, sid, "removed", action="reject", by="user", request_id=rid, now=op["at"],
                                   record={"op": op["id"]} | ({"label": op["label"]["label"]} if op.get("label") else {}))  # fmt: skip
    rejected = set(op["samples"])

    def not_x(before: dict):
        if before.get("person_id") != x or not rejected & set(before.get("samples") or []):
            return None
        # nobody is named now: the label keeps none of X's samples (the inactive ones are detached, put back on undo)
        detached = sorted(set(before.get("samples") or []) - rejected)
        after = before | {"person_id": None, "source": None, "samples": [], "not": sorted(set(before.get("not") or []) | {x})}
        return after, {"person_id": None, "not_person_id": x, "sample": "rejected", "keep_unknown": False, "withdrawn": None,
                       "rejected": {"person_id": x, "samples": sorted(rejected), "op": op["id"], "detached": detached}}  # fmt: skip

    _label_step(store, op, rid, not_x)


def _unreject(store, op: dict) -> None:
    x, uid = op["person"], op["request_id"]
    for sid in op["samples"]:
        data = store.read_sample(x, sid)
        if data is not None and data.get("state") == "removed":
            store.update_sample(x, sid, {"state": "active"}, action="undo", by="user", request_id=uid, now=op["at"],
                                record={"undo_of": op["undo_of"], "op": op["id"], "from": "removed", "to": "active"})  # fmt: skip
    _label_step(store, op, f"{uid}:{op['undo_of']}", _restore(store, op))


def _merge(store, op: dict) -> None:
    person, sample = op["person"], op["sample"]
    if store.person(person) is None and not store.person_dir(person).exists():
        return  # forgotten meanwhile: nothing is recreated
    if store.read_sample(person, sample["sample_id"]) is None:  # 1. the union's sample, pending
        store._publish_sample(person, sample["sample_id"], sample | {"pending_op": op["id"]})
    for sid in op["replaced"]:  # 2. what it replaces stops counting (soft: restorable, never deleted)
        data = store.read_sample(person, sid)
        if data is not None and (data.get("state") or "active") == "active":
            store.set_sample_state(person, sid, "removed", action="merge", by="import", request_id=op["request_id"], now=op["at"],
                                   record={"into": op["import_id"], "op": op["id"]})  # fmt: skip
    result = store.person_dir(person) / "enrollments" / f"{op['import_id']}.json"
    if Vault.read_json(result) is None:  # 3. the import's answer
        Vault.write_json(result, op["result"])
    _set_pending(store, person, sample["sample_id"], None)  # 4. it counts


# -- cancelling (forget, withdrawn consent) --------------------------------------------------------------


def cancel(store, op: dict, forgotten: set = frozenset()) -> None:
    """Undo whatever part of `op` was applied (idempotently; nothing is written for a forgotten person, whose data
    goes anyway), then delete its intent."""
    _busy.op = op["id"]
    try:
        kind, rid = op["kind"], f"rollback:{op['id']}"
        if kind == "move":
            a, b = op["from"], op["to"]
            for src, new in op["pairs"]:
                store.remove_sample_ids(b, [new])
                data = store.read_sample(a, src)
                if a not in forgotten and data and data.get("state") == "moved" and (data.get("moved_to") or {}).get("sample_id") == new:
                    store.update_sample(a, src, {"state": "active", "moved_to": None}, action="rollback", by="recovery",
                                        request_id=rid, record={"op": op["id"], "from": "moved", "to": "active"})  # fmt: skip
            _label_revert(store, op, op["request_id"])
        elif kind == "merge":
            person = op["person"]
            store.remove_sample_ids(person, [op["sample"]["sample_id"]])
            for sid in op["replaced"]:
                data = store.read_sample(person, sid)
                last = ((data or {}).get("history") or [{}])[-1]
                if person not in forgotten and data and data.get("state") == "removed" and last.get("op") == op["id"]:
                    store.update_sample(person, sid, {"state": "active"}, action="rollback", by="recovery", request_id=rid,
                                        record={"op": op["id"], "from": "removed", "to": "active"})  # fmt: skip
            for extra in (store.person_dir(person) / "enrollments" / f"{op['import_id']}.json",
                          store.person_dir(person) / "enrollment" / f"{op['import_id']}.omiaudio"):  # fmt: skip
                remove(extra)
        elif kind == "unmove":
            a, b = op["from"], op["to"]
            for src, new in op["pairs"]:
                data = store.read_sample(a, src)
                last = ((data or {}).get("history") or [{}])[-1]
                if a not in forgotten and data and data.get("state") == "active" and last.get("op") == op["id"]:
                    store.update_sample(a, src, {"state": "moved", "moved_to": {"person_id": b, "sample_id": new}}, action="rollback",
                                        by="recovery", request_id=rid, record={"op": op["id"], "from": "active", "to": "moved"})  # fmt: skip
                if b not in forgotten:
                    _set_pending(store, b, new, None)  # still B's
            _label_revert(store, op, f"{op['request_id']}:{op['undo_of']}", undo_of=op["undo_of"])
        elif kind == "unreject":
            x = op["person"]
            for sid in op["samples"]:
                data = store.read_sample(x, sid)
                last = ((data or {}).get("history") or [{}])[-1]
                if x not in forgotten and data and data.get("state") == "active" and last.get("op") == op["id"]:
                    store.update_sample(x, sid, {"state": "removed"}, action="rollback", by="recovery", request_id=rid,
                                        record={"op": op["id"], "from": "active", "to": "removed"})  # fmt: skip
            _label_revert(store, op, f"{op['request_id']}:{op['undo_of']}", undo_of=op["undo_of"])
        # a reject only removes voice data: whatever part of it happened stands
    finally:
        _busy.op = None
    store.db.set_meta("relabel_pending", "1")
    store.samples_changed()
    complete(store, op)


def _label_revert(store, op: dict, key: str, undo_of: str | None = None) -> None:
    """Put the label back as it was before the request `key` changed it, if that change still stands."""
    where = op.get("label")
    if not where or store.db.one("SELECT 1 FROM conversations WHERE id=?", (where["conversation_id"],)) is None:
        return
    conv_id, label = where["conversation_id"], where["label"]
    store.sync_conversation(conv_id)
    rec = store.request_result(conv_id, key)
    if store.request_result(conv_id, f"rollback:{op['id']}") is not None:
        _schedule_render(store, conv_id)
        return
    if rec is None:
        return
    if undo_of is not None:  # an undo restored `before` of `undo_of`; its rollback puts that request's `after` back
        original = store.request_result(conv_id, undo_of) or {}
        made, back = original.get("before"), original.get("after")
    else:
        made, back = rec.get("after"), rec.get("before")
    states = store.labels(conv_id)
    current = store.persisted({label: states.get(label) or {}}).get(label) or {}
    if back is None or made is None or any(current.get(k) != made.get(k) for k in DECISION_KEYS):
        return  # changed since: the later decision stands
    states[label] = back
    store.write_labels(conv_id, states, request=(f"rollback:{op['id']}", {"label": label, "rollback_of": key}))
    _schedule_render(store, conv_id)
