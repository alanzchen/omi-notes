"""The tracked deploy scripts (deploy/), checked without building a release or touching launchd (2026-11-24 R1).

- build-release.sh stopped on the word "xfailed" after the tests passed, and wrote index_schema 8 whatever the code says.
- user-service.sh loaded the new agent but launchd left the spawn pended for ~11 minutes until a kickstart."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

from omi_notes.db import SCHEMA_VERSION

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "deploy" / "build-release.sh"
SERVICE = ROOT / "deploy" / "user-service.sh"


@pytest.mark.parametrize("summary, ok", [
    ("1191 passed, 1 xfailed in 201.41s (0:03:21)", True),
    ("1188 passed, 4 skipped, 1 xfailed, 1 xpassed in 3.0s", True),
    ("1190 passed, 1 failed in 200s", False),
    ("3 failed, 1188 passed, 1 xfailed in 199s", False),
    ("no tests ran in 0.01s", False),
])  # fmt: skip
def test_the_release_gate_accepts_xfailed_and_refuses_failed(summary, ok):
    r = subprocess.run(["bash", str(BUILD), "--check-summary", summary], capture_output=True, text=True)
    assert (r.returncode == 0) is ok, (summary, r.returncode, r.stderr)


def test_the_manifest_records_the_index_schema_of_the_code_it_ships():
    r = subprocess.run(["bash", str(BUILD), "--index-schema", str(ROOT / "backend")], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.strip() == str(SCHEMA_VERSION), (r.stdout, r.stderr)
    assert '"index_schema": 8' not in BUILD.read_text()


def test_load_kickstarts_the_agent_after_bootstrapping_it():
    text = SERVICE.read_text()
    body = re.search(r"^load\(\) \{.*?^\}", text, re.S | re.M).group(0)
    boot, kick = body.find("launchctl bootstrap"), body.find("launchctl kickstart")
    assert boot != -1 and kick > boot, "a bootstrapped agent can stay pended (2026-11-23: 11 min); start it explicitly"
    assert "kickstart -k" not in body, "never kill a process that is already running"
