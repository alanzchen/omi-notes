# Design: one device identity per capture (rebuild, sweep, live PUT)

Status: proposal (2026-11-25, nightly R4), from Carbon IT3 C3-01..05. Not implemented; line numbers are at `3460bf4`.

## 1. The invariant

**A capture has exactly one device id: the `device_id` of the first artifact admitted for it (`captures.device_id`).**
- **Every later artifact must name it exactly:** chunk, tombstone and seal, in any folder.
- **Its files live in exactly one folder,** the vault's folder for that id: `safe_component(id)`, matched case-insensitively.
- **Every row carries that id;** every path uses the folder it was actually listed in.

This is already the live rule. A PUT whose chunk or seal names another device than the capture's row gets `409 capture_identity_conflict` (`ingest.py:456, 621, 842`). Rebuild and sweep must apply the same rule, not a folder-name approximation of it.

**One function:** `CaptureIdentity.admit(capture_id, folder, named_device) -> refusal | None`.
- **It holds one registry entry per `capture_id`,** not per `(folder, capture)`: `capture_id` is globally unique.
- **The entry's device is seeded once,** in this order:
  1. the index's `captures.device_id`: the live index for the sweep, the read-only previous index for a full rebuild;
  2. else `capture.json`'s `device_id`;
  3. else the earliest-received admitted artifact (receipt time, then rank chunk < seal, then sequence).

  It's the same order ingest uses, because the first PUT created the row.
- **A folder** is admitted for an entry only if `safe_component(id).casefold() == folder.casefold()`.
- **Callers:**
  - the full-rebuild chunk and tombstone ops (`rebuild.py:224–286`);
  - `seal.json` (`:296–306`);
  - `index_capture_orphans` and `sweep` (`:772–830`);
  - `_refuse_if_missing` (`:569`);
  - the three live-PUT comparisons (they become calls to the same comparison).
- **`apply_capture_evidence` takes both values:** `device_id` for row values, `folder` for paths.

## 2. The findings mapped

| Finding | Violation today | How the invariant closes it |
|---|---|---|
| **C3-01** an empty `raw/<other>/<cap>/` overrides an intact capture; or shadows a missing one | `rebuild.py:308` writes `report.devices[cap] = owner.value` per folder, even with no artifacts; last folder wins | The registry is per `capture_id`. An empty folder admits nothing and sets nothing. Two folders with artifacts for one `capture_id`: only the folder matching the seeded id is admitted; the other's files are reported problems (kept, never deleted). **`report.devices` stays keyed by `capture_id`, but only admitted artifacts may write it.** |
| **C3-02** `seal.json` never checked; `_refuse_if_missing` ignores a seal's device | `:296–306` index the seal without `admit`; `:582` compares chunks only | The seal goes through `admit(seal.device_id)`. The refusal check also compares the previous `captures.device_id` with the rebuilt one, so a 0-chunk sealed capture in the wrong folder, or a seal splitting the capture row from its chunks, is refused like a missing upload. |
| **C3-03** a sweep orphan joins a capture under a colliding id | `:775` skips indexed chunks (`skip=have`) and seeds `_CaptureDevice` only from capture.json, so the first orphan header decides | The sweep seeds from the live index's `captures.device_id` (seed 1). An orphan naming another id is a problem, not indexed, and the next rebuild has nothing inconsistent to refuse. |
| **C3-05** evidence looked up by the device id, not the folder | `:376` via `vault.capture_json_path(device, …)`, called at `:637, :801` | Paths always use the listed folder. The id is used only for row values. A case-folded vault moved to a case-sensitive disk still finds its `capture.json`. |

## 3. What it must never do

**Never refuse a legitimate real-vault layout.** Each of these is one capture, one id, one folder:
- **Watch parts:** a `watch-<uuid>` header in the `watch-<uuid>` folder.
- **Pendant captures:** a UUID header in its own folder.
- **`migrate-vault` legacy captures:** headers written from the old rows into `safe_component(id)`.
- **Captures without capture.json:** seeded from the index, or from their first artifact.
- **Case-only APFS folder sharing between different captures:** the identity is per capture, so two captures with ids differing only in case may share one folder.

It never deletes, moves or rewrites a vault file. A refused artifact is a reported problem, and the existing rule decides: an acknowledged one refuses the rebuild (503, previous index kept).

**Real-vault regression check** (Carbon confirmed the real vault rebuilds clean today; it must stay that way):
- **Copy:** a full `build()` of an APFS clone (`cp -cR`, copy-on-write) of `/Users/alan/OmiNotes` into a temp index directory, never the live vault or index.
- **Compare** it with the live index, opened `mode=ro`. The set of `(capture_id, chunk_sequence, device_id)`, every `captures.device_id`, and the seal and event counts must be identical, with no new `problems`, no `StartupIncomplete`, and no `coverage`/`speech`/`losses` row whose device isn't its capture's.
- **When:** before any deploy of the implementation.

## 4. Test plan

- **Carbon's IT3 probes:** C3-01, C3-02 and C3-03, ported with the fixed outcome asserted, written first and red on `3460bf4`.
- **C3-05:** a unit test that every evidence path is built from the listed folder, with `safe_component` monkeypatched to make the id and folder differ.
- **Existing tests stay green:** R2's `test_rebuild_device_identity.py`, plus `test_rebuild_chunk_device.py` and `test_rebuild_device_shapes.py`.
- **One real-vault-shape fixture:**
  - **The shapes:** two Pendant UUID captures (with and without capture.json, one tombstoned), a sealed 0-chunk capture, a Watch `watch-<uuid>` capture, a `migrate-vault` legacy capture, and two captures whose ids differ only by case and share a folder.
  - **The assertion:** a rebuild from the previous index gives the same identity set, and the sweep adopts an orphan chunk of each shape.
- **Size:** about 120 lines in `rebuild.py` (the registry, call sites, the evidence path/id split) plus a small `ingest.py` refactor onto the shared comparison. About 300 lines of tests in two files.

## 5. C3-04 (`Database.close` reads `in_transaction` while another connection waits in `busy_timeout`)

**Defer: fold it into this implementation; not a live defect today.**
- **Why it isn't live:**
  - The live server never calls `close()`; `create_app` doesn't.
  - Its callers (`rebuild.build`, `migrate._check`, `not_ready_app.retry_now`) each close a Database only they use, on one thread, so no other connection of that object can be inside `BEGIN IMMEDIATE`.
  - The freeze needs that.
- **The trivial fix for later:** count open `tx()` scopes in Python (`self._active_tx`, changed under `_opened_lock`) and check that counter in `close()` instead of each connection's `in_transaction`. That touches no SQLite mutex.
- **Also later:** skip connections already closed directly.
