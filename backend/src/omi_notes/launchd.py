"""Render a launchd service without shell-evaluating settings or embedding credentials."""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
from pathlib import Path

from .settings import BACKEND_DIR, env_file, load_settings

LABEL = "com.omi-notes.server"


def service_plist(backend: Path, config: Path, *, user: str | None = None) -> bytes:
    values = {
        "Label": LABEL,
        "ProgramArguments": [str(backend / ".venv/bin/omi-notes"), "serve", "--log-file-only"],
        "WorkingDirectory": str(backend),
        "EnvironmentVariables": {
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "OMI_NOTES_ENV_FILE": str(config),
        },
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "Umask": 0o077,
        "ExitTimeOut": 60,
    }
    if user is not None:
        values["UserName"] = user
    return plistlib.dumps(values)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"], default="install", nargs="?")
    parser.add_argument("--write-plist", type=Path, help="Prepare a plist without loading it")
    parser.add_argument("--user", help="Run as this user in a system LaunchDaemon (requires --write-plist)")
    args = parser.parse_args()
    if args.user and not args.write_plist:
        parser.error("--user requires --write-plist; install the reviewed plist into /Library/LaunchDaemons")
    path = args.write_plist or Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    if args.action == "uninstall":
        subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)
        path.unlink(missing_ok=True)
        print(f"Removed {path}")
        return
    settings = load_settings()
    settings.logs_dir.mkdir(parents=True, exist_ok=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(service_plist(BACKEND_DIR, env_file().absolute(), user=args.user))
    path.chmod(0o600)
    if not args.write_plist:
        subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)
        subprocess.run(["launchctl", "bootstrap", domain, str(path)], check=True)
    print(f"Prepared {path}; rotating logs in {settings.logs_dir}")


if __name__ == "__main__":
    main()
