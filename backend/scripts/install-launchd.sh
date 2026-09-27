#!/bin/sh
# Install/update the login service, or prepare a system service with --write-plist and --user.
set -eu
BACKEND_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -x "$BACKEND_DIR/.venv/bin/python" ]; then
    echo "Run uv sync --locked in $BACKEND_DIR first." >&2
    exit 1
fi
exec "$BACKEND_DIR/.venv/bin/python" -m omi_notes.launchd "$@"
