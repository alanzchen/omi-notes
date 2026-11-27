#!/usr/bin/env bash
# Build a backend release from HEAD (git archive), same Python, hard-linked models; test, doctor,
# manifest and plist. Prints the plist path. Usage: build-release.sh "<adds text>"
set -euo pipefail
# The release gate: pytest's whole summary line, at least one test passed, and nothing but skipped, xfailed, xpassed
# (non-strict), deselected or warnings beside it. "xfailed" is an expected failure, not a failure (2026-11-23 the old
# check `!= *failed*` stopped a green release on that word); a failure, an error or any other text is refused
# (ASTRA-20261124-IT2-01). pytest's own exit status is enforced separately, by `set -o pipefail` below.
tests_ok() {
    local extra='(, [0-9]+ (skipped|xfailed|xpassed|deselected|warnings?))*'
    [[ $1 =~ ^[1-9][0-9]*\ passed${extra}\ in\ [0-9.]+s(\ \([0-9:]+\))?$ ]]
}
# The disposable index schema the shipped code builds (the manifest used to say 8 whatever the code said).
index_schema() { sed -nE 's/^SCHEMA_VERSION = ([0-9]+).*/\1/p' "$1/src/omi_notes/db.py"; }
case "${1:-}" in  # checks without building anything (backend/tests/test_deploy_scripts.py)
    --check-summary) tests_ok "$2"; exit ;;
    --index-schema) index_schema "$2"; exit ;;
esac
cd "$(dirname "$0")/.."  # this script's own tree (a detached worktree archives its own HEAD), not a fixed checkout
[[ -z $(git status --porcelain -- backend contracts) ]] || { echo "backend has uncommitted changes" >&2; exit 1; }
R=~/.local/share/omi-notes/releases
CUR=$(~/.config/omi-notes/user-service.sh status 2>&1 | sed -nE 's/.*current: (.*)\/backend$/\1/p')
REV=$(git rev-parse HEAD)  # once: the name, the archive and the manifest name the same commit (ASTRA-20261124-IT2-03)
NAME=$(date +%Y%m%d-%H%M%S)-${REV:0:7}; NEW=$R/$NAME
mkdir -p $NEW; git archive "$REV" backend contracts deploy | tar -x -C $NEW  # deploy/: the gate's deploy-script tests run in the release
mkdir -p $NEW/backend/models; ln $CUR/backend/models/*.onnx $NEW/backend/models/
cd $NEW/backend
UV_PYTHON=/opt/homebrew/opt/python@3.13/bin/python3.13 uv sync --frozen --extra diarization >/dev/null 2>&1
[[ $(.venv/bin/python --version) == "Python 3.13.18" ]] || { echo "wrong python" >&2; exit 1; }
SUMMARY=$(env -u OMI_NOTES_ENV_FILE uv run --frozen --extra diarization pytest -o addopts="" -q -p no:cacheprovider 2>&1 | tail -1)
echo "tests: $SUMMARY" >&2
tests_ok "$SUMMARY" || exit 1
FAILS=$(OMI_NOTES_ENV_FILE=$HOME/.config/omi-notes/server.env .venv/bin/omi-notes doctor 2>&1 | grep -cE "✗|FAIL" || true)
[[ $FAILS == 0 ]] || { echo "doctor failures: $FAILS" >&2; exit 1; }
SCHEMA=$(index_schema "$NEW/backend")
python3 - "$NEW" "$NAME" "$CUR" "$SUMMARY" "$1" "$SCHEMA" "$REV" <<'PY'
import hashlib, json, sys, pathlib, datetime
new, name, cur, summary, adds = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3]), sys.argv[4], sys.argv[5]
schema = int(sys.argv[6])
old = json.load(open(cur / "release.json"))
src = {p.relative_to(new).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((new / "backend").rglob("*"))
       if p.is_file() and not {".venv", "__pycache__", "models", ".pytest_cache"} & set(p.parts)}
rev = sys.argv[7]  # the archived commit, resolved once before archiving
json.dump({"release": str(new), "backend": str(new / "backend"), "git_revision": rev,
           "built_from": "git archive of the committed revision (no local changes)",
           "built_at": datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ"), "replaces": cur.name,
           "python": "Homebrew python@3.13 3.13.18", "index_schema": schema, "vault_format": "reads 1-4 (unchanged)", "prompt_version": 3,
           "adds": [adds], "rollback": (f"safe to {cur.name} (no vault or index change)" if old.get("index_schema") == schema else
                        f"to {cur.name} (index schema {old.get('index_schema')}): no vault format change; it rebuilds its own index "
                        f"from the vault (this release builds schema {schema})"),
           "backend_tests": {"summary": f"{summary} (release venv, diarization extras)"}, "models": old["models"], "source_sha256": src},
          open(new / "release.json", "w"), indent=1)
PY
OMI_NOTES_ENV_FILE=$HOME/.config/omi-notes/server.env .venv/bin/python -m omi_notes.launchd --write-plist ~/.config/omi-notes/user-agent/com.omi-notes.server.$NAME.plist >/dev/null
echo ~/.config/omi-notes/user-agent/com.omi-notes.server.$NAME.plist
