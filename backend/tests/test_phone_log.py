"""`PUT /v1/diagnostics/phone-log`: the phone's diagnostic tail, beside the server log (not the vault).
Synthetic lines only."""

from __future__ import annotations

from omi_notes import phone_log

from .conftest import AUTH


def put(client, body, headers=AUTH):
    return client.put("/v1/diagnostics/phone-log", json=body, headers=headers)


def test_the_server_advertises_and_stores_the_phone_log(client, settings):
    assert "phone_log" in client.get("/v1/status", headers=AUTH).json()["features"]
    r = put(client, {"device_id": "phone-1234", "app_version": "0.1.0 (42)", "lines": [
        {"at": "2026-11-07T21:21:41.000Z", "level": "info", "category": "ble", "message": "connected to Omi"},
        {"at": "2026-11-07T21:21:42.000Z", "level": "warning", "category": "upload", "message": "two\nlines"}]})
    assert r.status_code == 200 and r.json() == {"stored": 2}
    text = (settings.logs_dir / "phone" / "phone-1234.log").read_text()
    assert text.splitlines() == ["2026-11-07T21:21:41.000Z info [ble] connected to Omi · 0.1.0 (42)",
                                 "2026-11-07T21:21:42.000Z warning [upload] two lines · 0.1.0 (42)"]
    assert not any(p.name == "phone" for p in settings.vault_dir.rglob("*")), "never in the vault"


def test_it_needs_the_token_and_bounded_well_formed_batches(client, settings):
    assert put(client, {"device_id": "p", "lines": []}, headers={}).status_code == 401
    assert put(client, {"lines": []}).status_code == 422
    assert put(client, {"device_id": "p", "lines": ["x"]}).status_code == 422
    big = {"device_id": "p", "lines": [{"message": "x" * 400}] * 300}
    assert put(client, big).status_code == 413
    assert put(client, {"device_id": "../../etc/x", "lines": [{"message": "m"}]}).status_code == 200
    assert (settings.logs_dir / "phone" / ".._.._etc_x.log").exists(), "the device id can't leave the folder"


def test_a_full_log_is_rotated(tmp_path, monkeypatch):
    monkeypatch.setattr(phone_log, "MAX_FILE_BYTES", 100)
    for _ in range(3):
        phone_log.append(tmp_path, {"device_id": "p", "lines": [{"message": "m" * 80}]})
    assert (tmp_path / "phone" / "p.log.1").exists() and (tmp_path / "phone" / "p.log").stat().st_size < 200
