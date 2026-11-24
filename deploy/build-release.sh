#!/usr/bin/env bash
# Build a backend release from HEAD (git archive), same Python, hard-linked models; test, doctor,
# manifest and plist. Prints the plist path. Usage: build-release.sh "<adds text>"
set -euo pipefail
cd /Users/alan/Developer/omi-notes
[[ -z $(git status --porcelain -- backend contracts) ]] || { echo "backend has uncommitted changes" >&2; exit 1; }
R=~/.local/share/omi-notes/releases
CUR=$(~/.config/omi-notes/user-service.sh status 2>&1 | sed -nE 's/.*current: (.*)\/backend$/\1/p')
NAME=$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD); NEW=$R/$NAME
mkdir -p $NEW; git archive HEAD backend contracts | tar -x -C $NEW
mkdir -p $NEW/backend/models; ln $CUR/backend/models/*.onnx $NEW/backend/models/
cd $NEW/backend
UV_PYTHON=/opt/homebrew/opt/python@3.13/bin/python3.13 uv sync --frozen --extra diarization >/dev/null 2>&1
[[ $(.venv/bin/python --version) == "Python 3.13.18" ]] || { echo "wrong python" >&2; exit 1; }
SUMMARY=$(env -u OMI_NOTES_ENV_FILE uv run --frozen --extra diarization pytest -o addopts="" -q -p no:cacheprovider 2>&1 | tail -1)
echo "tests: $SUMMARY" >&2
[[ $SUMMARY == *passed* && $SUMMARY != *failed* ]] || exit 1
FAILS=$(OMI_NOTES_ENV_FILE=$HOME/.config/omi-notes/server.env .venv/bin/omi-notes doctor 2>&1 | grep -cE "✗|FAIL" || true)
[[ $FAILS == 0 ]] || { echo "doctor failures: $FAILS" >&2; exit 1; }
python3 - "$NEW" "$NAME" "$CUR" "$SUMMARY" "$1" <<'PY'
import hashlib, json, sys, pathlib, datetime, subprocess
new, name, cur, summary, adds = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3]), sys.argv[4], sys.argv[5]
old = json.load(open(cur / "release.json"))
src = {p.relative_to(new).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((new / "backend").rglob("*"))
       if p.is_file() and not {".venv", "__pycache__", "models", ".pytest_cache"} & set(p.parts)}
rev = subprocess.check_output(["git", "-C", "/Users/alan/Developer/omi-notes", "rev-parse", "HEAD"], text=True).strip()
json.dump({"release": str(new), "backend": str(new / "backend"), "git_revision": rev,
           "built_from": "git archive of the committed revision (no local changes)",
           "built_at": datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ"), "replaces": cur.name,
           "python": "Homebrew python@3.13 3.13.18", "index_schema": 8, "vault_format": "reads 1-4 (unchanged)", "prompt_version": 3,
           "adds": [adds], "rollback": f"safe to {cur.name} (no vault or index change)",
           "backend_tests": {"summary": f"{summary} (release venv, diarization extras)"}, "models": old["models"], "source_sha256": src},
          open(new / "release.json", "w"), indent=1)
PY
OMI_NOTES_ENV_FILE=$HOME/.config/omi-notes/server.env .venv/bin/python -m omi_notes.launchd --write-plist ~/.config/omi-notes/user-agent/com.omi-notes.server.$NAME.plist >/dev/null
echo ~/.config/omi-notes/user-agent/com.omi-notes.server.$NAME.plist
