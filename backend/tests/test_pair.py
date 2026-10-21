"""`omi-notes pair`: the link in the QR code is the phone's pairing contract (ConfigureLink.parse,
OmiBLETests/SettingsAndSimulatorTests.swift) and carries the bearer token. Synthetic tokens and URLs."""

from __future__ import annotations

import os
import re
import stat

import qrcode
from typer.testing import CliRunner

from omi_notes.cli import app as cli


def pair(monkeypatch, env: dict[str, str], *args: str) -> tuple[list[str], str]:
    links: list[str] = []
    monkeypatch.setattr(qrcode.QRCode, "add_data", lambda self, data, *a, **k: links.append(data))
    monkeypatch.setattr("omi_notes.cli._tailscale_url", lambda: None)  # never this Mac's tailscale
    result = CliRunner().invoke(cli, ["pair", *args], env=env)
    assert result.exit_code == 0, result.output
    return links, result.output


def test_pairing_generates_a_private_token_and_a_link_the_phone_parses(monkeypatch):
    links, out = pair(monkeypatch, {}, "--url", "https://mac.tail1234.ts.net")
    env_file = os.environ["OMI_NOTES_ENV_FILE"]  # tmp (hermetic_env)
    (token,) = re.findall(r"^OMI_NOTES_TOKEN=([0-9a-f]{64})$", open(env_file).read(), re.M)
    assert stat.S_IMODE(os.stat(env_file).st_mode) == 0o600
    assert links == [f"omi-notes://configure?url=https%3A%2F%2Fmac.tail1234.ts.net&token={token}"]
    assert "Generated a new token" in out and token not in out, "the token is only in the QR code and the env file"


def test_pairing_reuses_the_configured_token(monkeypatch):
    links, out = pair(monkeypatch, {"OMI_NOTES_TOKEN": "0123456789abcdef"}, "--url", "https://mac.tail1234.ts.net")
    assert links == ["omi-notes://configure?url=https%3A%2F%2Fmac.tail1234.ts.net&token=0123456789abcdef"]
    assert "Generated" not in out and not os.path.exists(os.environ["OMI_NOTES_ENV_FILE"])
