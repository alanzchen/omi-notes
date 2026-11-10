"""The status card's counts (`/v1/status`: conflicted notes, the newest note) cost the same whatever the history
(Astra, review of main 9b11b7c); work in SQLite VM steps at two sizes with identical answers. Fakes only."""

from __future__ import annotations

from .test_home_cost import Steps, sized  # noqa: F401 (fixture)


def test_the_status_counts_cost_the_same_whatever_the_history(sized, monkeypatch):
    steps = Steps(monkeypatch)
    small, big = sized(older=20), sized(older=2000)
    from omi_notes import views
    from omi_notes.pipeline.conversations import notes_conflicted, queue_counts

    for client in (small, big):
        db = client.app.state.speakers.pipeline.db
        db.execute("UPDATE conversations SET edited=0 WHERE id LIKE 'o%'")  # conflicts only among the recent rows
    out = {}
    for label, client in (("small", small), ("big", big)):
        db = client.app.state.speakers.pipeline.db
        assert queue_counts(db)["notes_conflicted"] == notes_conflicted(db)
        steps.measure(lambda: (notes_conflicted(db), views.last_note_at(db)))
        (counts, last), n = steps.measure(lambda: (notes_conflicted(db), views.last_note_at(db)))
        out[label] = (counts, last, n)
    assert out["small"][:2] == out["big"][:2] and out["small"][0] == 5
    assert out["big"][2] <= out["small"][2] * 1.3 + 2000, out
