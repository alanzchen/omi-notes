"""`PUT /v1/diagnostics/phone-log`: the phone's diagnostic tail, beside the server log (not the vault).
Synthetic lines only."""

from __future__ import annotations

from omi_notes import phone_log

from .conftest import AUTH


PHONE = "phone-0b6f1c7e-3c1d-4a5e-9f20-6d7c8b9a0e1f"  # what the app sends: "phone-" + its lowercase install UUID


def put(client, body, headers=AUTH):
    return client.put("/v1/diagnostics/phone-log", json=body, headers=headers)


def test_the_server_advertises_and_stores_the_phone_log(client, settings):
    assert "phone_log" in client.get("/v1/status", headers=AUTH).json()["features"]
    r = put(client, {"device_id": PHONE, "app_version": "0.1.0 (42)", "lines": [
        {"at": "2026-11-07T21:21:41.000Z", "level": "info", "category": "ble", "message": "connected to Omi"},
        {"at": "2026-11-07T21:21:42.000Z", "level": "warning", "category": "upload", "message": "two\nlines"}]})
    assert r.status_code == 200 and r.json() == {"stored": 2}
    text = (settings.logs_dir / "phone" / f"{PHONE}.log").read_text()
    assert text.splitlines() == ["2026-11-07T21:21:41.000Z info [ble] connected to Omi · 0.1.0 (42)",
                                 "2026-11-07T21:21:42.000Z warning [upload] two lines · 0.1.0 (42)"]
    assert not any(p.name == "phone" for p in settings.vault_dir.rglob("*")), "never in the vault"


def test_it_needs_the_token_and_bounded_well_formed_batches(client, settings):
    assert put(client, {"device_id": PHONE, "lines": []}, headers={}).status_code == 401
    assert put(client, {"lines": []}).status_code == 422
    assert put(client, {"device_id": PHONE, "lines": ["x"]}).status_code == 422
    big = {"device_id": PHONE, "lines": [{"message": "x" * 400}] * 300}
    assert put(client, big).status_code == 413


def test_a_full_log_is_rotated(tmp_path, monkeypatch):
    monkeypatch.setattr(phone_log, "MAX_FILE_BYTES", 100)
    for _ in range(3):
        phone_log.append(tmp_path, {"device_id": PHONE, "lines": [{"message": "m" * 80}]})
    assert (tmp_path / "phone" / f"{PHONE}.log.1").exists() and (tmp_path / "phone" / f"{PHONE}.log").stat().st_size < 200


# astra-review-42-20261108


def test_only_canonical_phone_ids_are_accepted(client, settings):
    """R42-03: an id is validated, not sanitized (distinct ids must not collide or leave the folder)."""
    for bad in ["../../etc/x", "phone-A/B", "phone-A_B", "p", PHONE.upper(), PHONE + "x", " " + PHONE, "phone-" + "0" * 36]:
        r = put(client, {"device_id": bad, "lines": [{"message": "m"}]})
        assert r.status_code == 422 and r.json()["error"] == "invalid_log", bad
    assert not (settings.logs_dir / "phone").exists() or not any((settings.logs_dir / "phone").iterdir())


def test_an_empty_batch_creates_no_file(client, settings):
    assert put(client, {"device_id": PHONE, "lines": []}).json() == {"stored": 0}
    assert not (settings.logs_dir / "phone" / f"{PHONE}.log").exists()


def test_the_phone_log_folder_is_bounded_in_total(tmp_path, monkeypatch):
    """R42-03: many install ids (reinstalls, or a client changing ids) can't grow the folder without
    bound: the oldest other phones' files go first, and files past the age limit go too."""
    import os
    import uuid

    monkeypatch.setattr(phone_log, "MAX_FILE_BYTES", 300)
    monkeypatch.setattr(phone_log, "MAX_TOTAL_BYTES", 2_000)
    folder = tmp_path / "phone"
    ids = [f"phone-{uuid.uuid4()}" for _ in range(60)]
    for n, device in enumerate(ids):
        for _ in range(3):
            phone_log.append(tmp_path, {"device_id": device, "lines": [{"message": f"{n} " + "m" * 120}]})
        os.utime(folder / f"{device}.log", (1_000 + n, 1_000 + n))  # deterministic age order
    files = list(folder.iterdir())
    assert sum(f.stat().st_size for f in files) <= phone_log.MAX_TOTAL_BYTES + phone_log.MAX_FILE_BYTES * 2
    assert len(files) < 20
    assert (folder / f"{ids[-1]}.log").exists(), "the phone that just wrote keeps its log"
    assert not (folder / f"{ids[0]}.log").exists(), "the oldest went first"

    stale = folder / f"phone-{uuid.uuid4()}.log"
    stale.write_text("old\n")
    os.utime(stale, (1, 1))  # far beyond the age limit
    phone_log.append(tmp_path, {"device_id": ids[-1], "lines": [{"message": "m"}]})
    assert not stale.exists()


def test_malformed_line_fields_are_422_not_500(client):
    """R42-04: a non-string level (or other field) is refused, never an uncaught TypeError."""
    for line in [{"level": [], "message": "m"}, {"level": {}, "message": "m"}, {"message": ["m"]},
                 {"category": {"a": 1}, "message": "m"}, {"at": 5, "message": "m"}]:
        r = put(client, {"device_id": PHONE, "lines": [line]})
        assert r.status_code == 422 and r.json()["error"] == "invalid_log", line
    assert put(client, {"device_id": PHONE, "lines": [{"level": "loud", "message": "m"}]}).status_code == 200, "an unknown level reads as info"
