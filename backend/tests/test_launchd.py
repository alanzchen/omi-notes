from __future__ import annotations

import logging
import plistlib

from omi_notes import cli
from omi_notes.launchd import service_plist
from omi_notes.settings import Settings


def test_service_uses_external_config_and_vault_log_directory(tmp_path):
    release = tmp_path / "release & one"
    config = tmp_path / "private configuration.env"
    config.write_text(f"INDEX_DIR='{tmp_path}/state/index'\nVAULT_DIR='{tmp_path}/vault'\n")
    settings = Settings(_env_file=config)
    result = plistlib.loads(service_plist(release, config))
    assert result["EnvironmentVariables"]["OMI_NOTES_ENV_FILE"] == str(config)
    assert result["ProgramArguments"] == [str(release / ".venv/bin/omi-notes"), "serve", "--log-file-only"]
    assert result["WorkingDirectory"] == str(release)
    assert settings.logs_dir == tmp_path / "state/logs"
    assert "UserName" not in result
    assert result["KeepAlive"] is True


def test_system_service_runs_as_requested_user(tmp_path):
    result = plistlib.loads(service_plist(tmp_path, tmp_path / "server.env", user="alan"))
    assert result["UserName"] == "alan"
    assert result["Umask"] == 0o077


def test_service_logging_rotates_and_preserves_recent_errors(tmp_path):
    root = logging.getLogger()
    previous = root.handlers[:]
    previous_level = root.level
    root.handlers = []
    try:
        cli._setup_logging(Settings(index_dir=tmp_path / "index"), to_file=True, console=False)
        assert len(root.handlers) == 1
        handler = root.handlers[0]
        assert handler.maxBytes > 0 and handler.backupCount > 0
        handler.maxBytes = 100
        root.error("first event " + "x" * 90)
        root.error("latest event")
        handler.flush()
        assert "latest event" in (tmp_path / "logs/omi-notes.log").read_text()
        assert (tmp_path / "logs/omi-notes.log.1").exists()
    finally:
        for handler in root.handlers:
            handler.close()
        root.handlers = previous
        root.setLevel(previous_level)
