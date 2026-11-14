#!/bin/sh
# Install, start, stop or inspect the omi-asr sidecar as a user LaunchAgent (com.omi-notes.asr, KeepAlive,
# loopback only, models from the sidecar's own Hugging Face cache on the internal disk, downloads disabled).
# The cache is the sidecar's own (OMI_ASR_HF_HOME), not ~/.cache/huggingface: that one may be moved to an external
# volume, where a launchd process blocks in open() on a privacy (TCC) check nobody can answer while the screen is
# locked (2026-11-14: every model load hung).
#   scripts/launchagent.sh install|uninstall|status|check
set -eu
LABEL=com.omi-notes.asr
HERE=$(cd "$(dirname "$0")/.." && pwd)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/omi-notes-asr.log"
PORT=${OMI_ASR_PORT:-18793}
DOMAIN="gui/$(id -u)"
HF="${OMI_ASR_HF_HOME:-$HOME/Library/Application Support/omi-notes-asr/hf}"
case "$HF" in  # one absolute spelling, by name only (nothing resolved), for the check, the -d test and the plist
  /*) ;;
  *) HF="$PWD/$HF" ;;
esac

# The sidecar's own check (names and link text only: nothing on an external volume is looked at), before any test
# that follows the path (ASTRA-20261114-IT1-01, IT3-01).
check_cache() {
  if ! why=$(cd "$HERE" && HF_HOME="$HF" HF_HUB_CACHE="$HF/hub" .venv/bin/python -c \
      'import sys; from omi_asr.server import cache_problem; p = cache_problem(); print(p or ""); sys.exit(1 if p else 0)'); then
    echo "refusing: $why" >&2; exit 1
  fi
  [ -d "$HF/hub" ] || { echo "no model cache at $HF/hub (copy the three models there first)" >&2; exit 1; }
}

case "${1:-status}" in
install)
  [ -x "$HERE/.venv/bin/python" ] || { echo "run 'uv sync' in $HERE first" >&2; exit 1; }
  check_cache
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
check)  # the cache this install would use, checked; nothing installed
  check_cache
  echo "$HF"
  ;;
status)
  launchctl print "$DOMAIN/$LABEL" | grep -E "state|pid|last exit" || true
  curl -fsS "http://127.0.0.1:$PORT/health"; echo
  ;;
*) echo "usage: $0 install|uninstall|status|check" >&2; exit 2 ;;
esac
