# Design: unreadable speaker files (consent, samples) and derived voice data

Status: proposal (2026-11-25, nightly R7), after Carbon IT4–IT6. C4-01, C5-01/02 and C6-01 are four rounds of
regressions in one path, all descending from 159a42f ("skip an unreadable file"). Not implemented; lines at `0227082`.

## 1. Invariants, ranked (a higher rule wins)

1. **A real opt-out wins, unconditionally and immediately.** Opt-outs: forget a person; their consent withdrawn (a
   readable `consent.json` without attestation, `{}`); the global acknowledgment withdrawn; `auto_assign` off; unknown
   voices off. They drop automatic names and prune vectors exactly as with every file readable.
2. **An unreadable file is never evidence.** It doesn't prune or downgrade derived data, and it doesn't name anyone new.
3. **One bad file never wedges the snapshot or other people.** It is skipped, counted and surfaced; the samples index is
   never emptied.

**One owner per rule:**
- **`SpeakerStore.person_policy(person_id, prefs) -> OPTED_OUT | FROZEN | NORMAL`** decides 1 and 2 from readable facts:
  1. forgetting marker or no person → `OPTED_OUT`;
  2. `me` → `NORMAL`;
  3. acknowledgment withdrawn, or a readable consent without attestation → `OPTED_OUT`;
  4. an unreadable `consent.json` or an unreadable sample file of theirs → `FROZEN`;
  5. else `NORMAL`.

  `auto_assign` off and unknown voices off are global opt-outs, applied by the two writers below before the policy.
- **The two derived-state writers are the only places it is consulted:**
  - `vector_labels` (every prune);
  - one new label-state filter, `SpeakerStore.settle_states(current, proposed, prefs)`, used by both `_relabel` and
    `identify`.

  No call site checks deferral, consent files or opt-outs itself.
- **Rule 3 belongs to the snapshot builder and `load_samples`,** as now: skip and record, one transaction, surfaced via
  `speaker_files_unreadable`.

## 2. Shapes considered

- **(i) Fix up the per-person deferral** (current `0227082`): add opt-out checks to the `_relabel` deferral, then to
  `identify`, then to `vector_labels`. Every fix is another call-site check, which is exactly how C4-01 → C5-02 → C6-01
  happened. **Rejected.**
- **(ii) Freeze with opt-out precedence (recommended).** For a `FROZEN` person, `settle_states` keeps the current state of
  every label currently auto-named for them, and gives them no new automatic name. `vector_labels` keeps their named
  vectors. An opt-out maps to `OPTED_OUT` or a global switch first, so it is never frozen. When the file is readable
  again, the person is `NORMAL` and the next relabel decides.
- **(iii) Fail closed per person** (867e0b9 behaviour, scoped): exclude a person with an unreadable file from the
  snapshot and from all derived passes. Their card would vanish (worse than a marked one), and the prune and opt-out
  semantics still have to be decided: it's (ii) plus lost display. **Rejected.**

**KEEP / DROP versus `0227082` (for shape ii):**
- **KEEP:**
  - 159a42f: the transactional `load_samples`, skip-and-record with stat keys, and the consent skip.
  - 3460bf4: builds under the speaker lock, issue surfacing, `warm` tolerance, `put_person` once/stale, the suggestions
    flags, the `people.json` guard.
  - 55b6a29: last-known `attested_at` (display only).
  - 0227082: `read_consent` (non-object = unreadable), the memo, `relabel_pending` on a readable-set change.
- **DROP:**
  - the `consent_unreadable` branch in `vector_labels` (55b6a29 / 0227082);
  - the deferral block in `_relabel` and `deferred_people` (0227082).

  Both are replaced by `person_policy` + `settle_states`. Dropping either *without* the replacement brings back C4-01
  (pruned vectors on a torn consent) or C5-02 (a skipped sample → names dropped → vectors pruned). With the replacement,
  nothing comes back. C6-02 and C6-03 fold in: a reload sets `relabel_pending` when the *skipped* set changes too, and
  `settle_states` never writes a state for a label that had none.
- **Estimate:** about −30 / +70 source lines (store.py, conversations.py). About 200 test lines: Carbon IT4–IT6
  reproducers ported with fixed outcomes, plus an opt-out matrix (5 opt-outs × {torn consent, unreadable sample}).

## 3. Deployability without the unreadable-file chain

- **The chain is entangled.** 3460bf4's issue surfacing reads `skipped_samples` / `unreadable_consent` introduced by
  159a42f (`git show 3460bf4 -- backend/src`, `_publish_problems`), and 55b6a29 / 0227082 build on both. No pure-revert
  subset keeps 3460bf4.
- **Coherent safe set: `867e0b9`, the last commit before 159a42f.** No reverts are needed: a release branch pointed at
  `867e0b9`.
  - **What it contains:** ffc2a78 (IT1-01 snapshot), d4dec23, 977ac3f, 867e0b9, and every earlier d861a4e.. commit
    (bounded `/status`, `/issues`, counters, startup completeness, and the rest).
  - **Evidence:**
    - its full suite was green in R2 (`round2` log: 1280 passed, 2 skipped, 1 xfailed);
    - Carbon IT3 (pinned `867e0b9`) rebuilt the real Mac Studio vault cleanly;
    - Carbon IT1/IT2/IT3 verdicts were ACCEPT, not deploy-blocking.
- **Known open at 867e0b9:**
  - C2-01: a narrow read-your-write race on `/people`; the next build heals it.
  - C2-02: one corrupt speaker file keeps the snapshot stale (`ready:false`), `load_samples`' autocommit DELETE can empty
    the samples index, `warm` stops before People, and `PUT /v1/people` can 500 after writing the note.
  - C2-04/C2-05 (nits); C3-01..05 (device-identity edges, docs/proposals/device-identity.md); C3-04; C1-03/04.
- **Compared with production `d861a4e`:**
  - **Same with a corrupt file:** the C2-02 failure modes exist there too. `GET /v1/people` reconciles per request and
    500s on a corrupt sample, and the same autocommit DELETE runs.
  - **Never prunes on an unreadable file:** 867e0b9 fails closed, which is the privacy-safe direction; there is no C4-01,
    C5-02 or C6-01 there.
  - **Fixed relative to d861a4e:** IT1-01 to IT1-04 and IT2.
- **Before deploying:**
  - full backend at `867e0b9`;
  - `test_people_snapshot.py`, `test_rebuild_device_identity.py`, `test_database_close_contract.py`;
  - the real-vault clone rebuild check from docs/proposals/device-identity.md §3.

## 4. Carry list (next night)

- C6-02 and C6-03 (fold into §2);
- C4-02 (malformed sample shapes outside the per-file try);
- C4-03 (stat key misses an equal-size replacement);
- journal replay with no prior row (`speakers/journal.py:153`: defer, don't cancel);
- a deferred/frozen person's new conversations: not auto-named; with unknown voices off, the vector isn't kept
  (reprocess recovers it);
- the device-identity implementation (docs/proposals/device-identity.md);
- IT1-05/06, IT4-05.
