# Speaker learning

Committee decision (Claude Opus 5.5 + GPT-6-Astra, converged 2026-09-27). Recognize the wearer
("me") and a few recurring people across conversations. Everything lives in the vault
(`docs/vault.md`); the iPhone app is the teaching and correction UI. Omi reference paths below are
relative to `/Users/alan/Developer/_ref/omi`.

## Model and voices

- **Embedding:** WeSpeaker ResNet34 (`wespeaker_en_voxceleb_resnet34_LM.onnx`, CC-BY-4.0) through
  sherpa-onnx `SpeakerEmbeddingExtractor` (`fetch-models --speakers`; same optional `diarization`
  extra). TitaNet stays for diarization. Omi measured its operating points on pendant audio with
  this architecture (`backend/utils/stt/speaker_match.py`, `conversation_speakers.py`); they are
  **priors**, recalibrated by `omi-notes speakers bench`. Every sample records model + sha;
  vectors from different models are never compared.
- **Voices stage** (inside transcription, while the PCM is in memory, for provider or local
  labels): map each label to its turns on the submitted-audio clock (before utterance merging);
  use turns ≥ 1.5 s that don't overlap another label (±0.25 s), trimmed 0.25 s at each end,
  excluding spacers/losses; longest first, up to 30 s in clips ≤ 10 s (cf. Omi
  `backend/utils/stt/sync_speaker_evidence.py`). Label centroid = duration-weighted normalized
  mean; "mixed" if clip spread > 0.6. Skipped when `speaker_labels_consistent = false`.
  With text-only cloud transcription, use the original local diarizer turns for recognition,
  rather than the larger windows sent to STT; speaker labels follow transcript order and
  overlapping speech stays excluded. HTTP request boundaries are not extra voice evidence.
- Unmatched labels' vectors are kept in memory only, unless **unknown-voice storage** is opted in.

## Matching

- Person model = normalized centroid of **confirmed** samples only (enrollment + user
  assignments; cap 20). Automatic matches never become samples (no drift).
- Accept a label → person iff cosine distance < **0.50** (Omi pooled threshold), runner-up margin
  ≥ **0.10**, evidence ≥ **5 s** from ≥ 2 clean turns, label not mixed. Several labels may map to
  one person (diarization over-splits), but within a conversation the label closest to a person is
  the runner-up for the others: another label keeps that name only if it is < 0.10 further (with
  only one enrolled person there is no other runner-up; end to end, two different `say` voices sat
  0.04 and 0.44 from the enrolled one). `source: user` assignments are sticky; `not: [pid]` blocks
  a person for that label.
- **Per-person activation gate:** automatic naming is on by default (`SPEAKER_AUTO_ASSIGN=true`),
  but applies to a person only once they have ≥ 3 confirmed samples from ≥ 2 sessions on different
  days beyond enrollment **and** a leave-one-out check passes (each sample matches the centroid of
  the others within threshold and margin). For the **wearer only**, an accepted enrollment plus
  confirmations from ≥ 3 distinct recordings can activate naming on the same day; the
  leave-one-out check still applies. This lets the wearer explicitly calibrate their own voice
  without a calendar delay. Repeated labels from one recording do not meet that exception.
  Before activation: suggestions only. Enrollment alone does not activate auto-naming.
  Auto names carry an "auto" badge and
  show similarity evidence (distance, margin, seconds), never a "probability".
- **Owner rule** (`match.OwnerRule`, versioned; evidence study `spk/a0-20261109`, Revision 4 of the
  voices-hub plan): a pure restriction on top of everything here. The wearer is auto-named only on the
  label with the highest raw cosine to their centroid in a conversation with ≥ 2 labels, at raw cosine
  ≥ **0.88**; in a single-label conversation at raw ≥ **0.80**. A second over-split wearer label stays
  unnamed. A stored label whose vector wasn't kept still counts towards "≥ 2 labels", so a relabel
  never applies the single-label rule to a conversation the voices stage saw with several voices.
- **Recording-mean (rm) agreement** (`speakers/space.py`): anyone else is auto-named only when the rm
  ranking puts the same person first too. GA, the mean of the currently consent-eligible stored
  vectors (`vector_labels`) and eligible samples, is computed in memory whenever models are built and
  never persisted; people's centroids are the median of their GA-centred samples. A label is centred
  by its conversation's mean: all label vectors at the voices stage (`rm_basis: conversation`), the
  stored consented ones in a relabel (`partial`), GA with fewer than 2 or when the label lies within
  0.20 of that mean (`ga`). `rm_basis` is kept in the label's evidence in `speakers.json`. No
  threshold is loosened. rm also orders "possibly X" hints (≥ 200 GA vectors) and picks who a
  recurring unknown voice might be.
- **Enrollment-only model:** once a person holds ≥ 60 s of enrollment speech (pendant or imported),
  their centroid comes from enrollment samples alone. Activation still judges their confirmed samples
  exactly as before.
- **Continuous wearer speech:** once enrolled and active, a single long turn can qualify with
  ≥ 10 s of evidence, ≥ 2 disjoint clean clips of ≥ 3 s each, and a stricter distance < 0.25.
  Margin and mixed-voice checks still apply. This avoids rejecting a long monologue just because
  local diarization correctly sees one continuous turn. Other people retain the ≥ 2-turn rule.
- Whenever people/samples change, the worker re-runs the pure assignment over stored voices and
  re-renders the notes whose labels changed — **from cache, no LLM call**. "Re-summarize with
  names" is an explicit action.

## Names in notes

- Render precedence: voice identification > LLM `speaker_names` (self-introductions, hints only) >
  "Speaker N".
- Frontmatter gains read-only projections: `people: ["[[Alan]]", "[[Priya]]"]` and
  `speakers: ["S1: [[Alan]]", "S2: [[Priya]]", "S3: ?"]`. Confidence and provenance live in
  `speakers.json` in the conversation dir. Editing frontmatter is **not** a correction channel (yet).
- The LLM prompt receives "S1 = the owner (Alan); S2 = Priya" for new summaries (`PROMPT_VERSION`
  bump; LLM cache key includes the speakers hash).

## People

- `People/<Name>.md`: frontmatter `omi_person_id`, `name`, `aliases`, `omi_me: true|false`; created
  once by the server, then user-owned (rename freely; identity is the id). Obsidian backlinks show
  their conversations.
- Voice data: `_omi/people/<id>/samples|enrollment|enrollments`. **Forget voice** first clears
  the person's label assignments (marking those labels `forgotten`, so their voice is never stored
  again, even as an unknown voice), prunes those labels' vectors, keeps only the *decision* of a
  global enrollment result (so the reading is not learned again), then deletes that folder and
  re-renders affected notes back to "Speaker N". A retry after a crash finishes what is left.
- Taking a label back from someone (renaming it, "Unknown speaker", "Not X") deletes the samples
  that assignment created — a label state lists them (`samples`), so they follow it when a
  re-transcription moves it to another label number (retraction is only ever by those ids, never
  by a label number that may have been another assignment's): a repudiated confirmation must not
  train anyone's voice.
- Forget runs in this order, under the speaker lock: the index catches up with every
  `speakers.json`; the person's labels are marked forgotten *before* anything may move them (a
  pending or in-flight move to a new transcript then carries the marker instead of dropping the
  association); pending moves finish; unreferenced voices files go; vectors are pruned; the
  person's voice data is deleted — removed and moved samples and their history included, and the
  `moved` records other people's folders keep of samples moved *to* this person (they hold this
  person's voice).

## Voices hub

The app's 声纹 hub (features `voice_review`, `voice_calibration`, `enrollment_import`). Nothing here
deletes a voiceprint except forgetting a person; everything else is a state change with history.

- **Sample states** (vault format 6, raised under the per-vault meta lock before the first state or
  flag is written, so an older backend refuses the vault instead of training on a removed sample):
  each sample file may carry `state` (`active` | `removed` | `moved`; absent = active), `revision`,
  `history` [{at, action, by, request_id, from?, to?, …}] and `flag` {reasons, evidence_fingerprint,
  flagged_at, resolved?: {decision, at, fingerprint}}. **`store.sample_eligible`** (active only) is
  the one rule for what feeds matching, activation, hints, suggestions, GA and calibration. A flag
  never changes eligibility. New samples also keep their `clips` (submitted-audio bounds), `voices_file`,
  `audio_sha`, a `caption` (the phrase they overlap) and F0.
- **F0** (`audio/pitch.py`, numpy YIN from the evidence study: 30 ms window, 10 ms hop, 70–400 Hz,
  energetic voiced frames): measured at the voices stage while the PCM is in hand and kept in the
  voices file only next to a kept vector. A clip needs ≥ 20 voiced frames, a sample ≥ 100, else F0 is
  unknown. `omi-notes speakers measure-f0` backfills from raw audio (or a person's enrollment audio);
  `omi-notes speakers import-f0 <bench data dir>` imports the 2026-11-08 bench's torchaudio F0 only
  where the sample's conversation (start within 0.05 s), label, voices generation, audio and clip
  starts (within 0.05 s) match, recording `f0_source`, estimator, clip ids and aggregation. Both only
  add fields, never overwrite, and report what they skipped. F0 is review evidence, never identity.
- **Review flags** (`speakers/flags.py`; computed by the calibration run): `pitch` — outside the
  person's own band, median ± max(25 Hz, 2.5 × MAD × 1.4826), no fixed 165 Hz split; `score` — raw
  cosine to the robust centroid (geometric median; the enrollment-only centroid when there is one)
  below median − 3 × MAD × 1.4826; `enrollment` — ≥ 0.50 from an enrollment-only model. Statistics
  need ≥ 5 samples. Flags only order the review queue. A confirm records the flag's evidence
  fingerprint (reasons + the sample's F0 measurement), so unchanged evidence never asks again.
- **Review queue** (`speakers/review.py`): flagged samples first, then recent automatic names and
  "possibly X" labels (newest 60 conversations), then other active samples never confirmed. An item
  id is bound to its revision (`s.<sample>.<revision>`, `l.<conversation>.<label>.<speakers
  revision>`): a decision on a changed item is `409 stale_review`. confirm resolves a sample's flag
  or names a label; reject soft-removes a sample or blocks the person for a label; move copies the
  sample to the other person first (an intent with `moved_from`, reused on retry), then marks it
  `moved` and renames the label in its conversation that still lists it (a request entry in
  `speakers.json`), so later retractions follow the moved sample. Label decisions go through the
  naming path. `request_id` deduplicates durably (sample `history`, or `speakers.json` requests); the
  existing undo reverts sample decisions where nothing changed since and never brings back a
  forgotten person. A clip is cut from raw audio while it exists (`playable: false` with the caption
  kept otherwise; audio is never fabricated).
- **Calibration** (`speakers/calibration.py`, informational, never changes activation): per person,
  consistency with the robust centroid, and the matcher's actual decision evaluated with each
  conversation left out (models and the rm space rebuilt without it, user-named labels as truth):
  positive conversations (a miss is an error), named-other-person negatives (naming this person there
  is an error) and target-absent conversations (only user-reviewed ones; 0 for now), each with a
  one-sided 95 % Clopper–Pearson upper bound. `measured` exists only when such counts do; there is no
  pooled accuracy. Published to `_omi/speakers/calibration.json` only if its input fingerprint
  (eligible sample ids and states, consent, wearer, model, owner/flag/calibration versions, the
  user-named labels evaluated) still matches under the speaker lock; each run is appended to
  `calibration-log.jsonl`. Runs 60 s after the last sample or consent change, nightly at 03:10 local
  (judged from the file, so a rebuild doesn't repeat it), and on startup when missing or stale.
- **Enrollment import** (`speakers/imports.py`): a range of an existing recording (seconds from its
  start; raw audio required) or an uploaded m4a/wav ≤ 20 min, with `confirm_person: true` and the
  person's name echoed. Non-owners need the acknowledgment and their attestation, checked explicitly.
  The pendant enrollment's checks apply (≥ 20 s VAD speech, one voice, held-out clip). The import id
  derives from (person, source sha256, start, end); a range an earlier import of the same source
  covers returns it, an overlapping one is judged as the union and soft-removes what it replaces, so
  repeated audio never adds seconds. The sample is `source: enrollment` with `import` provenance and
  the source conversation as its session; the speech is kept as `.omiaudio` in the person's folder
  and deleted on forget.

## Enrollment (wearer, through the pendant)

1. The app requires a live, flowing capture and a server whose `/v1/status` lists the
   `voice_enrollment` feature — asked again right before starting, never a remembered answer, and
   only used if the attempt wasn't cancelled and the configured server is still the one asked (an
   older server would transcribe the reading) — shows consent text, then ~6 sentences (~50 s).
   Closing the screen while checking or reading ends the attempt (`cancelled`): a window must
   never stay open unseen, or it would swallow ordinary speech.
2. At start the phone journals an outbox event `voice_enrollment_start` (`capture_id`, `offset_us`,
   `enrollment_id`) and **holds that capture's chunks from the start offset until the start event
   is acknowledged**, so enrollment speech can never reach STT unmarked. A start event that went
   missing unacknowledged is written again (the hold remembers it) while the audio stays held. A
   start event the server *rejects* releases the hold — it covers every later chunk of the capture,
   and holding all of that forever is worse than the reading being transcribed; with the feature
   check this is a server bug. At finish (or interruption) it sends `voice_enrollment_end`
   (`end_offset_us`, `outcome`), forcing a chunk rotation.
3. The server treats the window as explicit splits: a conversation inside it is discarded as
   "voice enrollment" **without STT** (reprocessing and resummarize never transcribe it either),
   and its raw audio is protected until the result is decided. A window whose end never arrives
   (the phone crashed; the end landed in another capture) is, once stale, closed at the end of its
   capture's audio and decided `interrupted` — the reading stays excluded.
4. After `processed_through` covers the end: decode the window; require ≥ 20 s of VAD speech,
   ≥ 80 % of 3 s windows within 0.5 of the window centroid (else "another voice"), level/clipping
   checks; verify with a **disjoint** held-out clip. States: `waiting_audio` → `processing` →
   `accepted` | `needs_another_sample` (reason). "Accepted" means enrolled, not calibrated.
5. On accept: store a sample and the wearer's own audio (`.omiaudio`) for re-embedding after a model
   change.

## Suggestions (recurring unknown voices) — opt-in

Off by default. With unknown-voice storage enabled: candidates are unassigned labels with ≥ 10 s of
speech (Omi `SIGNIFICANT_SECONDS`) whose raw audio still exists; average-linkage clustering at
0.50; suggest clusters spanning ≥ 3 conversations on ≥ 2 days, ranked by conversations × seconds,
max 5. Near an existing person → "Is this Priya?"; the loudest recurring voice while no `me`
exists → "Is this you?". Dismissals persist with a 7-day cooldown (cf. Omi
`backend/routers/speaker_tag_prompts.py`). "Keep unknown" is different and permanent: every member
label gets `source: "unknown"` in its `speakers.json` (sticky like a user name: never auto-named,
never suggested again, kept across rebuilds and re-transcriptions; the owner can still name it
later). Unknown embeddings are pruned with raw retention.

## Naming from the phone

- Every clip comes with the transcript text it overlaps (phrase level: segments have no word
  timing, so the phone shows the phrase without highlighting); a clip nothing overlaps has empty
  text, never another moment's sentence.
- A suggestion carries the conversation its representative clip is from, up to 3 clips there, one
  clip from another day when a member has one (`other_day`), and its `scope`: every conversation
  naming it would change, which the phone confirms before assigning.
- Every label change records what it changed (`before`/`after` in the request entry of
  `speakers.json`). `POST /v1/speakers/undo` puts back exactly that, label by label, only where the
  change still stands (a later decision is left alone and reported as skipped); voiceprints that
  request created are removed, the person and their other confirmations stay. Taking a label from
  a previously named person withdraws the voiceprints it gave them to
  `<person folder>/withdrawn/<request hash>/` (inside the person's folder, so forgetting them
  deletes these too) for 24 hours; undo puts them back. A label is undone all or nothing: if that
  person was forgotten or the withdrawn voiceprints are past the window, it is reported as
  skipped and nothing changes.
- Naming re-renders notes from cache; it never queues a new summary (that stays the explicit
  "Re-summarize with names").

## Consent (design as if BIPA / Texas CUBI apply)

- Inert until the user enrolls or names someone. One-time in-app acknowledgment before recognizing
  anyone other than the wearer, stored in `_omi/speakers/settings.json`; its text states it does
  **not** establish anyone else's consent or legal compliance.
- Every non-wearer voiceprint comes from an explicit naming action, which records a person-level
  attestation that the person knows. Unknown-voice storage is a separate opt-in.
- Embeddings never go to providers; the LLM only sees names. No third-party audio is kept beyond
  raw retention (clips are rendered on demand while raw exists).
- **What a conversation's voices file may keep** (one rule, `SpeakerStore.vector_labels`): the
  vector of a label named for the wearer or for someone with consent (acknowledged + attested);
  any other label's vector — unknown, or named without consent — only while unknown-voice storage
  is on and the raw audio exists; a forgotten label's never. The rule is re-applied idempotently on
  every retention pass and after every settings change, so a cleanup a crash interrupted finishes.
- A voices file is keyed by model, model hash, audio and transcript, and `speakers.json` names the
  one its label states were made against (`voices`): committed together with the states, so it is
  the only generation that counts. Every other file is removed by the startup sweep and by forget
  — except, while the states wait to be moved to a newer transcript, that transcript's file (the
  move compares the two).
- A state belongs to a voice, not a label number: on a new transcript it follows its voice to
  whichever label has it (one-to-one, closest first, within `SAME_VOICE` = 0.25 — the same
  speaker in the same audio), and is dropped when no same voice is found. A forgotten voice has
  no vector to follow, so once a voice in a conversation was forgotten (`speakers.json`
  `forgotten`, durable whatever later transcripts contain) every label nothing carried over to is
  forgotten too. States stay tagged with the transcript they were made for; only that move
  re-tags them, and it happens before anything renders, summarizes, relabels, assigns or forgets
  against a new transcript, also after a crash between the two.
- A note records the `speakers.json` revision it was rendered from (`render.speakers_revision`);
  any other revision re-renders it, however the labels changed (a correction during a render, a
  recovered file, a rebuild).

## API (bearer auth; errors in the existing shape)

| Endpoint | Shape |
|---|---|
| `GET /v1/people` | `{people:[{id,name,me,note_path,samples,sessions,auto_active,voice_ready,samples_active,samples_flagged,samples_removed,review_count,status_line,calibrated_at,measured}]}`; `samples` = active samples; `status_line` one plain line ("已启用", "停用：样本不一致", "需要更多样本"); `measured` null unless held-out counts exist: `{conversations, found_at_least, negative_conversations, wrong_at_most, target_absent_conversations, confidence}` |
| `GET /v1/people/{id}/samples?state=active\|flagged\|removed\|moved` | `{samples:[{id,person_id,state,revision,source,seconds,created_at,day,label,f0,f0_source,flag:{reasons,open,resolved}\|null,moved_to,moved_from,playable,clip?:{id,seconds,started_at},text,conversation,device,review_id}]}` |
| `POST /v1/samples/{id}/remove` / `restore` / `move` | `{request_id, expected_revision?, person_id (move)}` → `{sample, request_id, undo_token}`; repeated `request_id` answers the same; restore only from `removed` (else 409); a move to someone without consent is `409 consent_required` |
| `GET /v1/speakers/review?limit=10` | `{items:[{id,kind:sample\|label,person_id,sample_id?,label?,reasons,playable,clip?,text,conversation:{id,started_at,title},device}]}` |
| `POST /v1/speakers/review/{id}` | `{decision: confirm\|reject\|move, person_id?, request_id}` → `{item_id,decision,request_id,undo_token,…}`; a changed item is `409 stale_review` |
| `GET /v1/speakers/calibration` | `{calibration: <calibration.json>\|null, stale, pending}` |
| `POST /v1/people/{id}/enrollments/import` | JSON `{conversation_id, start, end, confirm_person: true, person_name}` or multipart (`file` m4a/wav ≤ 20 min, `confirm_person`, `person_name`, `start?`, `end?`) → 201 new / 200 already enrolled from this audio `{import_id,state,speech_s,sample_id,person_id,merged,source}`; `422 not_enough_speech` / `enrollment_rejected` / `person_name_mismatch`, `409 consent_required`, `410 audio_expired` |
| `PUT /v1/people/{uuid}` | `{name, me?, attest_knows?}` → 201/200 (client-minted id ⇒ idempotent; creates `People/<Name>.md`) |
| `DELETE /v1/people/{id}[?delete_note=true]` | forget voice (and optionally the note) |
| `GET /v1/conversations/{id}/speakers` | `{revision, transcript_sha, labels:[{label,person_id,name,source,distance,margin,evidence_s,clip_id,clips:[{id,seconds,started_at,text}],excerpt,kept_unknown}], audio_available}` |
| `PUT /v1/conversations/{id}/speakers/{label}` | `{person_id\|null, not_person_id?, keep_unknown?, expected_revision, request_id}` → `{revision, labels, relabeled_conversations}`; stale revision → 409; `request_id` dedupes sample creation; `keep_unknown: true` (with `person_id: null`) keeps the label unknown for good |
| `POST /v1/conversations/{id}/resummarize` | 202 (forced-LLM reprocess) |
| `GET /v1/speakers/suggestions?limit=5` | `{suggestions:[{id,kind,person_id?,clip_id,seconds,excerpt,conversations,days,conversation:{id,started_at,title},clips:[…,conversation_id],other_day:{…clip,conversation_id,conversation}\|null,scope:[{id,started_at,title}]}]}` (empty unless opted in) |
| `POST /v1/speakers/suggestions/{id}/dismiss` | 204 (hidden for 7 days; older phones) |
| `POST /v1/speakers/suggestions/{id}/assign` | `{person_id, request_id}` → `{relabeled_conversations}`; each member label is assigned under `request_id:<conversation>:<label>` |
| `POST /v1/speakers/suggestions/{id}/keep-unknown` | `{request_id}` → `{conversations}`; permanent (vault format 4) |
| `POST /v1/speakers/undo` | `{request_id, undo_request_id}` → `{undone:[conversation ids], skipped:[…], samples:{undone:[sample ids], skipped:[{id, reason}]}}`; idempotent per `undo_request_id`; also reverts sample decisions (review, remove, restore, move) made under `request_id` |
| `GET /v1/speakers/settings` / `PUT` | `{acknowledged_at, unknown_voices_enabled, auto_assign}` |
| `GET /v1/speakers/enrollments/{enrollment_id}` | `{state, speech_s, reason?}` |
| `GET /v1/clips/{clip_id}` | `audio/wav` 16 kHz mono PCM16 ≤ 10 s, rendered on demand; bounds validated to the label's turns; `410 Gone` when raw is expired. `sample.<sample id>.<i>`: a sample's own clip (or the start of its enrollment audio) |

The app downloads clips with an authenticated `URLSession` data task and plays them with
`AVAudioPlayer(data:)` — never a token in a URL, never Opus on the phone.

## iOS screens

- **Name this voice** (servers with the `name_voice` feature): one voice at a time — listen
  (play only on tap; waveform from the clip's own samples; clip and other-day choices only when
  they exist), answer ("Yes, Priya", "This is me", people shortcuts, search or add with a one-tap
  consent confirmation), then the next voice; a saved toast with Undo; "Not sure" skips for this
  session only, "Keep unknown" is permanent. Opened from Home ("N voices to name"), People, and a
  conversation's speakers. A suggestion's scope is confirmed before it is assigned or kept unknown.
- **People & Voices:** "You" card (enrollment state, "Teach my voice"); people list (samples,
  auto-active badge, swipe "Forget voice"); "Who is this?" suggestions (when opted in).
- **Enrollment sheet:** consent → pre-check (pendant streaming) → prompts → result polling.
- **Conversation speakers** (from recent conversations): each label with clip, excerpt, name,
  "auto" badge + evidence; tap to assign; "Re-summarize with names".
- **Recognition settings:** acknowledgment, unknown-voice opt-in, auto-assign toggle.
