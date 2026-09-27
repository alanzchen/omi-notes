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
  the others within threshold and margin). Before that: suggestions only. Enrollment alone is
  same-session evidence and does not activate auto-naming. Auto names carry an "auto" badge and
  show similarity evidence (distance, margin, seconds), never a "probability".
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
  person's voice data is deleted.

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
`backend/routers/speaker_tag_prompts.py`). Unknown embeddings are pruned with raw retention.

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
| `GET /v1/people` | `{people:[{id,name,me,note_path,samples,sessions,auto_active,voice_ready}]}` |
| `PUT /v1/people/{uuid}` | `{name, me?, attest_knows?}` → 201/200 (client-minted id ⇒ idempotent; creates `People/<Name>.md`) |
| `DELETE /v1/people/{id}[?delete_note=true]` | forget voice (and optionally the note) |
| `GET /v1/conversations/{id}/speakers` | `{revision, transcript_sha, labels:[{label,person_id,name,source,distance,margin,evidence_s,clip_id,excerpt}], audio_available}` |
| `PUT /v1/conversations/{id}/speakers/{label}` | `{person_id\|null, not_person_id?, expected_revision, request_id}` → `{revision, labels, relabeled_conversations}`; stale revision → 409; `request_id` dedupes sample creation |
| `POST /v1/conversations/{id}/resummarize` | 202 (forced-LLM reprocess) |
| `GET /v1/speakers/suggestions?limit=5` | `{suggestions:[{id,kind,person_id?,clip_id,seconds,excerpt,conversations,days}]}` (empty unless opted in) |
| `POST /v1/speakers/suggestions/{id}/dismiss` | 204 |
| `GET /v1/speakers/settings` / `PUT` | `{acknowledged_at, unknown_voices_enabled, auto_assign}` |
| `GET /v1/speakers/enrollments/{enrollment_id}` | `{state, speech_s, reason?}` |
| `GET /v1/clips/{clip_id}` | `audio/wav` 16 kHz mono PCM16 ≤ 10 s, rendered on demand; bounds validated to the label's turns; `410 Gone` when raw is expired |

The app downloads clips with an authenticated `URLSession` data task and plays them with
`AVAudioPlayer(data:)` — never a token in a URL, never Opus on the phone.

## iOS screens

- **People & Voices:** "You" card (enrollment state, "Teach my voice"); people list (samples,
  auto-active badge, swipe "Forget voice"); "Who is this?" suggestions (when opted in) with play,
  excerpt, "4 conversations · 3 days", actions: This is me / pick person / New person… / Dismiss.
- **Enrollment sheet:** consent → pre-check (pendant streaming) → prompts → result polling.
- **Conversation speakers** (from recent conversations): each label with clip, excerpt, name,
  "auto" badge + evidence; tap to assign; "Re-summarize with names".
- **Recognition settings:** acknowledgment, unknown-voice opt-in, auto-assign toggle.
