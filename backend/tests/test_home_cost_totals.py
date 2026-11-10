"""Home's per-day totals and the status card's counts cost the same whatever the history (Astra, review of main
9b11b7c); work in SQLite VM steps at two sizes with identical answers. Fakes only."""

from __future__ import annotations

from omi_notes import home

from .conftest import AUTH
from .test_home_cost import DAY, Steps, sized  # noqa: F401 (fixture)


def test_the_day_totals_are_kept_in_their_own_table_and_match_a_full_count(sized, monkeypatch):
    client = sized(older=30)
    db = client.app.state.speakers.pipeline.db
    days = client.get("/v1/conversations/recent?limit=50", headers=AUTH).json()["days"]
    # 12 a day: 8 short (k % 3 in 1, 2), minus the too-short one (k == 7, not listed); 4 deferred waiting; the
    # failure (k == 2) and the edited note (k == 5) need a look
    assert days[DAY] == {"short": 7, "deferred": 3, "requested": 0, "issues": 2}, days[DAY]
    stored = {r["day"]: dict(r) for r in db.query("SELECT * FROM day_totals")}
    assert stored[DAY]["short"] == 7
    # kept in step with every row change, in the same transaction
    db.execute("UPDATE conversations SET transcribe_op='op' WHERE id='r000001-001'")
    assert client.get("/v1/conversations/recent?limit=50", headers=AUTH).json()["days"][DAY]["requested"] == 1
    db.execute("DELETE FROM conversations WHERE id='r000001-004'")
    assert client.get("/v1/conversations/recent?limit=50", headers=AUTH).json()["days"][DAY]["short"] == 6
    before = {r["day"]: dict(r) for r in db.query("SELECT * FROM day_totals WHERE short > 0")}
    home.rebuild_totals(db)
    assert {r["day"]: dict(r) for r in db.query("SELECT * FROM day_totals WHERE short > 0")} == before
