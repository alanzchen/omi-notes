"""Apple Watch performance telemetry (`watch_perf` events) and the per-recording summary. A small
deterministic cohort (SYNTHETIC values, labelled as such) goes through the real event API: valid,
unknown and charging samples, duplicate and out-of-order batches, a relaunch and a reboot."""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from pathlib import Path

from .conftest import AUTH

WATCH = "watch-synthetic-perf"
REC = "5ee0a000-0000-4000-8000-00000000c0de"
T0 = datetime(2026, 10, 15, 9, 0, tzinfo=UTC).timestamp()


def iso(t: float) -> str:
    return datetime.fromtimestamp(t, UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def sample(minute: float, battery, *, event="periodic", state="recording", battery_state="unplugged", launch="l1",
           boot="boot-1", mono=True, counters=None, rec=REC) -> dict:  # fmt: skip
    t = T0 + minute * 60
    return {"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{rec}-{launch}-{minute}-{event}")), "at": iso(t),
            **({"mono_s": minute * 60.0} if mono else {}), "boot_id": boot, "launch_id": launch, "recording_id": rec,
            "event": event, "state": state,
            **({"battery": battery} if battery is not None else {}), "battery_state": battery_state,
            "counters": counters or {}, "gauges": {"outbox_parts": 1, "awaiting_ack": 0},
            "app": "0.1.0 (24)", "os": "11.0", "model": "SyntheticWatch1,1"}  # fmt: skip


def put(client, samples, *, batch=None, dropped=0):
    batch = batch or str(uuid.uuid4())
    body = {"device_id": WATCH, "type": "watch_perf", "at": samples[0]["at"],
            "data": {"schema": 1, "batch_id": batch, "samples": samples, "dropped_batches": dropped}}  # fmt: skip
    r = client.put(f"/v1/events/{batch}", json=body, headers=AUTH)
    assert r.status_code in (200, 201), r.text
    return batch


def summary(client):
    r = client.get("/v1/watch/performance?days=90", headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def test_an_hour_on_battery_gives_a_rate_and_charging_and_unknown_time_are_kept_apart(client):
    s = [sample(0, 0.90, event="start", counters={"callbacks": 0, "resends": 0})]
    s += [sample(m, round(0.90 - 0.001 * m, 3), counters={"callbacks": m * 700, "resends": 1}) for m in range(5, 65, 5)]
    s += [sample(65, None, battery_state="unknown"), sample(70, 0.83)]  # an unknown reading: not 0 %, not measured
    s += [sample(75, 0.84, battery_state="charging"), sample(80, 0.86, battery_state="charging")]  # charging: excluded
    s += [sample(85, 0.86, event="stopped", state="idle")]
    first = put(client, s[:8])
    put(client, s[8:])
    put(client, s[:8], batch=first)  # the same batch again (a resend): stored once
    (row,) = summary(client)["sessions"]
    assert row["complete"] and row["samples"] == len(s) and row["samples_battery_unknown"] == 1
    assert row["measured_s"] == 60 * 60 and row["rate_pp_per_hour"] == 6.0 and row["rate_quality"] == "ok", row
    assert row["battery_unknown_s"] == 10 * 60 and row["charging_s"] == 15 * 60
    assert row["battery_start"] == 0.9 and row["battery_end"] == 0.86
    assert row["counters"] == {"callbacks": 42_000, "resends": 1}
    assert row["builds"] == ["0.1.0 (24)"] and row["models"] == ["SyntheticWatch1,1"]


def test_late_out_of_order_and_duplicated_samples_count_once(client):
    s = [sample(m, round(0.80 - 0.0005 * m, 4)) for m in range(0, 50, 5)]
    put(client, s[5:])
    put(client, s[:5] + [s[6]])  # earlier samples arrive later, one sample twice in another batch
    (row,) = summary(client)["sessions"]
    assert row["samples"] == 10 and row["measured_s"] == 45 * 60 and not row["complete"], "open: no stop yet"
    assert row["rate_quality"] == "coarse", "2.25 points in 45 min: level steps dominate"


def test_a_relaunch_never_gives_negative_deltas_and_a_reboot_is_a_gap(client):
    s = [sample(0, 0.70, counters={"callbacks": 100}), sample(5, 0.69, counters={"callbacks": 5000})]
    s += [sample(10, 0.68, launch="l2", counters={"callbacks": 10}), sample(15, 0.67, launch="l2", counters={"callbacks": 3010})]
    # rebooted: a new boot id and no monotonic offset (the recording began before the reboot), so
    # nothing after it is measured
    s += [sample(20, 0.66, launch="l3", boot="boot-2", mono=False, counters={"callbacks": 0}),
          sample(25, 0.65, launch="l3", boot="boot-2", mono=False)]
    put(client, s)
    (row,) = summary(client)["sessions"]
    assert row["counters"]["callbacks"] == 4900 + 3000 and row["launches"] == 3
    assert [g["reason"] for g in row["gap_list"]] == ["restart", "no_monotonic_time"]
    assert row["measured_s"] == 15 * 60 and row["rate_pp_per_hour"] is None and row["rate_quality"] == "insufficient"


def test_a_long_silence_between_samples_is_a_gap_not_measured_time(client):
    put(client, [sample(0, 0.5), sample(5, 0.49), sample(60, 0.40), sample(65, 0.39)])
    (row,) = summary(client)["sessions"]
    assert row["gaps"] == 1 and row["measured_s"] == 10 * 60 and row["gap_list"][0]["reason"] == "no_samples"


def test_dropped_telemetry_is_reported_and_the_event_is_inert_for_notes(client, worker):
    put(client, [sample(0, 0.5)], dropped=3)
    body = summary(client)
    assert body["dropped_batches"] == {WATCH: 3}
    worker.tick(T0 + 3600)
    assert worker.db.one("SELECT count(*) AS n FROM conversations")["n"] == 0
    assert client.get("/v1/status", headers=AUTH).json()["features"][-1] == "watch_performance"


def test_the_phones_watch_perf_fixture_is_accepted_and_summarized(client):
    path = Path(__file__).parents[2] / "contracts/fixtures/swift/event_watch_perf.json"
    body = json.loads(path.read_text())
    r = client.put(f"/v1/events/{body['data']['batch_id']}", json=body, headers=AUTH)
    assert r.status_code == 201, r.text
    assert summary(client)["sessions"][0]["recording_id"] == body["data"]["samples"][0]["recording_id"]
