"""Independent deploy audit; never runs the service script or a real launchctl."""
import os
from pathlib import Path
import subprocess
import sys
import pytest

ROOT=Path(__file__).resolve().parents[2]  # the repository (Astra pointed this at her extracted copy)
BUILD=ROOT/"deploy/build-release.sh"
SERVICE=ROOT/"deploy/user-service.sh"

@pytest.mark.parametrize("text", ["1 passed, 1 error in 0.1s", "notpassed", "garbled passed trailing", "0 passed"])
def test_summary_refuses_error_or_garbage(text):
    result=subprocess.run(["bash",str(BUILD),"--check-summary",text],capture_output=True,text=True)
    assert result.returncode != 0, f"invalid summary accepted: {text!r}"

@pytest.mark.parametrize("body", [
    "def test_ok(): pass\ndef test_bad(): assert False\n",
    "import pytest\n@pytest.fixture\ndef broken(): raise RuntimeError('fixture error')\ndef test_error(broken): pass\ndef test_ok(): pass\n",
    "import pytest\n@pytest.mark.xfail(strict=True)\ndef test_unexpected_pass(): pass\ndef test_ok(): pass\n",
])
def test_real_pytest_nonzero_is_refused_before_summary(tmp_path,body):
    test=tmp_path/"test_gate.py";test.write_text(body)
    # The production shell flags and line24 pipeline; no release build runs.
    script='set -euo pipefail; SUMMARY=$("$PYTHON" -m pytest -o addopts="" -q "$CASE" 2>&1 | tail -1); echo RELEASE_ALLOWED'
    env=dict(os.environ,PYTHON=sys.executable,CASE=str(test))
    result=subprocess.run(["bash","-c",script],env=env,capture_output=True,text=True)
    assert result.returncode != 0 and "RELEASE_ALLOWED" not in result.stdout

@pytest.mark.parametrize("mode,code,kicks",[("success",0,1),("kickfail",3,2),("bootstrapfail",3,1),("notready",3,2)])
def test_switch_load_error_rolls_back_using_stubbed_commands(tmp_path,mode,code,kicks):
    src=SERVICE.read_text()
    funcs=src[src.index("load() {"):src.index('\ncase "${1:-}:$#"')]
    # Functions are the actual production text. Every launchctl is a shell stub;
    # all copies go inside tmp_path; validation/readiness checks are deterministic doubles.
    prefix=r"""
set -u
STATE="$ROOT/state"; AGENT="$ROOT/agent.plist"; DOMAIN=gui/test; LABEL=com.omi-notes.test
mkdir -p "$STATE"
printf new > "$ROOT/new.plist"
printf old > "$ROOT/old.plist"
say() { echo "$*"; }
validate() { return 0; }
system_gone() { return 0; }
stop_current() { echo stop >> "$ROOT/trace"; return 0; }
field() { cat "$1"; }
ready() { [ "$MODE" != notready ] || [ "$(cat "$1")" = old ]; }
launchctl() {
  echo "$*" >> "$ROOT/trace"
  if [ "$1" = bootstrap ] && [ "$MODE" = bootstrapfail ] && [ "$(cat "$AGENT")" = new ]; then return 1; fi
  if [ "$1" = kickstart ] && [ "$MODE" = kickfail ] && [ "$(cat "$AGENT")" = new ]; then return 1; fi
  return 0
}
"""
    result=subprocess.run(["sh","-c",prefix+funcs+'\nswitch "$ROOT/new.plist" "$ROOT/old.plist"\n'],env=dict(os.environ,ROOT=str(tmp_path),MODE=mode),capture_output=True,text=True)
    trace=(tmp_path/"trace").read_text()
    assert result.returncode == code, (result.stdout,result.stderr,trace)
    assert trace.count("kickstart gui/test/com.omi-notes.test") == kicks
    assert "kickstart -k" not in trace
    if mode != "success":
        assert (tmp_path/"agent.plist").read_text() == "old"
        assert "previous release restored" in result.stdout
