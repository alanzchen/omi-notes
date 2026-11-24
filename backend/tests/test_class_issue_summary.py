"""The class_choice_unreadable issue reads the worker's count and five examples (Astra IT5, 2026-11-24); an index whose
worker hasn't written that summary yet still answers the same from the full list."""

import json

from .conftest import AUTH


def _issue(client):
    return next(i for i in client.get("/v1/issues", headers=AUTH).json()["issues"] if i["code"] == "class_choice_unreadable")


def test_the_summary_and_the_pre_upgrade_list_give_the_same_issue(client):
    db = client.app.state.db
    names = [f"conv-{i:03d}" for i in range(12)]
    db.set_meta("class_unreadable", json.dumps(names))  # as an older release left it: no summary
    before = _issue(client)
    assert before["count"] == 12 and before["server_step"].endswith(", ".join(names[:5]))
    db.set_meta("class_unreadable_summary", json.dumps({"count": 12, "examples": names[:5]}))
    db.set_meta("class_unreadable", "not json: the request must not read it")
    assert _issue(client) == before
