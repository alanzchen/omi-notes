"""`_status.md` is rebuilt at most once a minute, however long its content stays the same (2026-11-27 R5).

Production (d861a4e) spent ~40% of a core idle: the throttle measured from the last *change* of the content, so once
the status stopped changing every worker tick rebuilt it, including `processed_ring_ranges` over every ring record
(2.49 M rows, ~2.8 s per call on the live index)."""

from __future__ import annotations

from omi_notes.pipeline import conversations

from .test_speaker_learning import env  # noqa: F401


def test_an_unchanged_status_is_still_rebuilt_at_most_once_a_minute(env, monkeypatch):
    settings, client, worker = env
    pipeline = worker.pipeline
    calls = {"n": 0}
    real = conversations.queue_counts

    def counted(db):
        calls["n"] += 1
        return real(db)

    monkeypatch.setattr(conversations, "queue_counts", counted)
    t = 1_900_000_000.0
    pipeline.render_status("v", t, force=False)
    pipeline.render_status("v", t + 61, force=False)  # a minute later: rebuilt (same content)
    built = calls["n"]
    for dt in (65, 70, 90, 120):  # within the minute after that build: skipped, though nothing changed
        pipeline.render_status("v", t + dt, force=False)
    assert calls["n"] == built, "an unchanged status was rebuilt inside the minute"
    pipeline.render_status("v", t + 122, force=False)
    assert calls["n"] == built + 1
