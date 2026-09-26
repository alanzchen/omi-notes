#!/bin/sh
# Install a LaunchAgent that runs `uv run omi-notes serve` at login and keeps it running.
#   ./scripts/install-launchd.sh            install (or update) and start
#   ./scripts/install-launchd.sh uninstall  stop and remove
set -eu

LABEL="com.omi-notes.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BACKEND_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL"
    exit 0
fi

UV="$(command -v uv || true)"
if [ -z "$UV" ]; then
    echo "uv not found on PATH (brew install uv)" >&2
    exit 1
fi

# Logs go to DATA_DIR/logs (DATA_DIR from backend/.env, else the default).
DATA_DIR="$HOME/.local/share/omi-notes"
if [ -f "$BACKEND_DIR/.env" ]; then
    value="$(grep -E '^DATA_DIR=' "$BACKEND_DIR/.env" | tail -n 1 | cut -d= -f2- || true)"
    if [ -n "$value" ]; then
        DATA_DIR="$(eval echo "$value")"
    fi
fi
LOG_DIR="$DATA_DIR/logs"
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$UV</string><string>run</string><string>--project</string><string>$BACKEND_DIR</string>
        <string>omi-notes</string><string>serve</string>
    </array>
    <key>WorkingDirectory</key><string>$BACKEND_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $PLIST; logs in $LOG_DIR"
