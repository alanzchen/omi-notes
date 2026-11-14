#!/bin/sh
# Install, start, stop or inspect the omi-asr sidecar as a user LaunchAgent (com.omi-notes.asr, KeepAlive,
# loopback only, models from the sidecar's own Hugging Face cache on the internal disk, downloads disabled).
# The cache is the sidecar's own (OMI_ASR_HF_HOME), not ~/.cache/huggingface: that one may be moved to an external
# volume, where a launchd process blocks in open() on a privacy (TCC) check nobody can answer while the screen is
# locked (2026-11-14: every model load hung).
#   scripts/launchagent.sh install|uninstall|status
set -eu
LABEL=com.omi-notes.asr
HERE=$(cd "$(dirname "$0")/.." && pwd)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/omi-notes-asr.log"
PORT=${OMI_ASR_PORT:-18793}
DOMAIN="gui/$(id -u)"
HF="${OMI_ASR_HF_HOME:-$HOME/Library/Application Support/omi-notes-asr/hf}"

case "${1:-status}" in
install)
  [ -x "$HERE/.venv/bin/python" ] || { echo "run 'uv sync' in $HERE first" >&2; exit 1; }
  [ -d "$HF/hub" ] && [ ! -L "$HF/hub" ] || { echo "no model cache at $HF/hub (copy the three models there first)" >&2; exit 1; }
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  tmp=$(mktemp)
  cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$HERE/.venv/bin/python</string><string>-m</string><string>omi_asr.server</string></array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OMI_ASR_HOST</key><string>127.0.0.1</string>
    <key>OMI_ASR_PORT</key><string>$PORT</string>
    <key>HF_HUB_OFFLINE</key><string>1</string>
    <key>HF_HOME</key><string>$HF</string>
    <key>HF_HUB_CACHE</key><string>$HF/hub</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
  plutil -lint "$tmp" >/dev/null
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  mv "$tmp" "$PLIST"
  launchctl bootstrap "$DOMAIN" "$PLIST"
  for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null && echo && exit 0
    sleep 1
  done
  echo "not healthy after 30 s; see $LOG" >&2; exit 1
  ;;
uninstall)
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  ;;
status)
  launchctl print "$DOMAIN/$LABEL" | grep -E "state|pid|last exit" || true
  curl -fsS "http://127.0.0.1:$PORT/health"; echo
  ;;
*) echo "usage: $0 install|uninstall|status" >&2; exit 2 ;;
esac
