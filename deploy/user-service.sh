#!/bin/sh
# Run the Omi Notes server as Alan's LaunchAgent (gui/<uid>): no sudo, never root.
#
#   user-service.sh status
#   user-service.sh start  [PLIST]   first start after the system daemon was retired (default: staged 2afefbb)
#   user-service.sh deploy PLIST     switch to another release's plist; the running one comes back on failure
#   user-service.sh rollback         go back to the plist that ran before the last deploy
#
# Make a release's plist with that release's own code (credentials stay in the env file):
#   OMI_NOTES_ENV_FILE=~/.config/omi-notes/server.env <release>/backend/.venv/bin/python -m omi_notes.launchd \
#       --write-plist ~/.config/omi-notes/user-agent/com.omi-notes.server.<name>.plist
#
# One writer: nothing starts while the system daemon exists or its plist is in /Library/LaunchDaemons,
# and a stopped server must be gone (no launchd job, pid exited, port free, vault host locks free)
# before another starts. A LaunchAgent runs only while Alan is logged in: it starts at login and
# stops at logout; after a reboot nothing runs until he logs in (FileVault asks first anyway).
#
# Exit codes: 0 ok; 1 refused, nothing changed; 2 the old server was not confirmed stopped (nothing
#             started); 3 the new plist failed and the previous one is running again; 4 nothing healthy
#             is running (see the messages).
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
say() { echo "[user-service] $*"; }

LABEL=com.omi-notes.server PORT=18765 WAIT_EXIT=90 WAIT_READY=${WAIT_READY:-150}
CONF=/Users/alan/.config/omi-notes
STATE=$CONF/user-agent
AGENT=/Users/alan/Library/LaunchAgents/$LABEL.plist
RELEASES=/Users/alan/.local/share/omi-notes/releases
ENV_FILE=$CONF/server.env
VAULT=/Users/alan/OmiNotes
LOCKS_ROOT="/Users/alan/Library/Application Support/omi-notes/locks"
SYSTEM_PLIST=/Library/LaunchDaemons/$LABEL.plist
if [ "${OMI_US_TEST:-}" = 1 ]; then  # harness only: a dummy server under a test label and port
    LABEL=com.omi-notes.test-agent PORT=$TEST_PORT STATE=$TEST_ROOT/state AGENT=/Users/alan/Library/LaunchAgents/$LABEL.plist
    RELEASES=$TEST_ROOT/releases ENV_FILE=$TEST_ROOT/server.env VAULT=$TEST_ROOT/vault LOCKS_ROOT=$TEST_ROOT/locks
    SYSTEM_PLIST=$TEST_ROOT/no-system.plist WAIT_EXIT=${TEST_WAIT:-20} WAIT_READY=${TEST_WAIT:-20}
fi
UID_=$(id -u)
DOMAIN=gui/$UID_
[ "$UID_" -ne 0 ] || { say "run this as alan, not root"; exit 1; }
[ "$(id -un)" = alan ] || { say "run this as alan"; exit 1; }
PB=/usr/libexec/PlistBuddy
field() { "$PB" -c "Print :$2" "$1" 2>/dev/null; }
canon() { (cd "$1" 2>/dev/null && pwd -P); }
LOCK_DIR="$LOCKS_ROOT/$(printf %s "$(canon "$VAULT")" | shasum -a 256 | cut -c1-16)"

validate() {  # $1 plist: this label, no UserName, `omi-notes serve --log-file-only` from a release, our env file
    plutil -lint "$1" >/dev/null 2>&1 || { say "invalid plist $1"; return 1; }
    [ "$(field "$1" Label)" = "$LABEL" ] || { say "wrong Label in $1"; return 1; }
    ! field "$1" UserName >/dev/null || { say "$1 sets UserName (system-only key)"; return 1; }
    ! field "$1" Program >/dev/null || { say "$1 sets Program"; return 1; }
    wd=$(field "$1" WorkingDirectory); prog=$(field "$1" ProgramArguments:0)
    [ "$prog" = "$wd/.venv/bin/omi-notes" ] && [ "$(field "$1" ProgramArguments:1)" = serve ] \
        && [ "$(field "$1" ProgramArguments:2)" = --log-file-only ] && ! field "$1" ProgramArguments:3 >/dev/null \
        || { say "$1 must run <release>/backend/.venv/bin/omi-notes serve --log-file-only"; return 1; }
    case "$wd" in "$(canon "$RELEASES")"/*/backend) ;; *) say "not a release backend: $wd"; return 1 ;; esac
    [ "$(canon "$wd")" = "$wd" ] && [ -x "$prog" ] || { say "missing or symlinked release: $wd"; return 1; }
    [ "$(field "$1" EnvironmentVariables:OMI_NOTES_ENV_FILE)" = "$ENV_FILE" ] || { say "wrong env file in $1"; return 1; }
}

job() {  # "absent" | "<pid> <program>" | "unknown"
    out=$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null); rc=$?
    [ "$rc" -ne 113 ] || { echo absent; return; }
    [ "$rc" -eq 0 ] || { echo unknown; return; }
    printf '%s\n' "$out" | awk '/^\tpid = /{p=$3} /^\tprogram = /{g=$3} END{print (p ? p : "none"), g}'
}
listeners() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u | tr '\n' ' '; }
locks_free() {
    for f in "$LOCK_DIR/api.lock" "$LOCK_DIR/worker.lock"; do
        [ ! -e "$f" ] || lockf -k -n -s -t 0 "$f" true || return 1
    done
}
system_gone() {
    launchctl print "system/$LABEL" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 113 ] && [ ! -e "$SYSTEM_PLIST" ]
}

wait_stopped() {  # $1 pid or none
    end=$(( $(date +%s) + WAIT_EXIT ))
    while [ "$(date +%s)" -lt "$end" ]; do
        if [ "$(job)" = absent ] && { [ "$1" = none ] || ! kill -0 "$1" 2>/dev/null; } && [ -z "$(listeners)" ] && locks_free; then
            return 0
        fi
        sleep 1
    done
    say "not confirmed stopped: job=$(job) pid=$1 listeners=[$(listeners)]"; return 1
}

ready() {  # $1 plist: launchd runs its program, that pid is the only listener and /healthz answers, twice
    want=$(field "$1" ProgramArguments:0) ok=0 end=$(( $(date +%s) + WAIT_READY ))
    while [ "$(date +%s)" -lt "$end" ]; do
        set -- "$1" $(job)
        if [ "${3:-}" = "$want" ] && [ "${2:-none}" != none ] && [ "$(listeners)" = "$2 " ] \
            && [ "$(curl -q --noproxy '*' -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/healthz")" = 200 ]; then
            ok=$((ok + 1)); [ "$ok" -lt 2 ] || { say "healthy: pid $2, $want"; return 0; }
        else ok=0; fi
        sleep 2
    done
    say "not ready: job=$(job) listeners=[$(listeners)]"; return 1
}

stop_current() {  # stop our job if loaded; 0 when confirmed gone
    j=$(job)
    [ "$j" != unknown ] || { say "launchctl cannot read $DOMAIN/$LABEL"; return 1; }
    [ "$j" != absent ] || { wait_stopped none; return; }
    pid=${j%% *}
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    wait_stopped "$pid"
}

load() {  # $1 plist: install as the agent and bootstrap it in Alan's GUI domain
    cp "$1" "$AGENT.tmp" && chmod 600 "$AGENT.tmp" && mv "$AGENT.tmp" "$AGENT" || { say "cannot install $AGENT"; return 1; }
    launchctl bootstrap "$DOMAIN" "$AGENT" || { say "bootstrap in $DOMAIN failed"; return 1; }
}

switch() {  # $1 new plist, $2 fallback plist (may be empty); both are copied first (they may be state files)
    mkdir -p "$STATE" && chmod 700 "$STATE"
    cp "$1" "$STATE/new.tmp" || exit 1; set -- "$STATE/new.tmp" "${2:+$STATE/fallback.tmp}" "$2"
    [ -z "$3" ] || cp "$3" "$2" || exit 1
    validate "$1" || exit 1
    [ -z "$2" ] || validate "$2" || exit 1
    system_gone || { say "the system daemon still exists (system/$LABEL or $SYSTEM_PLIST): retire it first"; exit 1; }
    stop_current || exit 2
    if load "$1" && ready "$1"; then
        [ -z "$2" ] || cp "$2" "$STATE/previous.plist"
        cp "$1" "$STATE/current.plist"
        say "running $(field "$1" WorkingDirectory)"; exit 0
    fi
    say "the new plist did not become healthy"
    stop_current || { say "and it did not stop; nothing else started"; exit 4; }
    if [ -n "$2" ] && load "$2" && ready "$2"; then say "previous release restored"; exit 3; fi
    stop_current
    say "NOTHING IS RUNNING. Recovery: $0 start <a known good plist in $STATE>"; exit 4
}

case "${1:-}:$#" in
    status:1)
        say "domain $DOMAIN job: $(job); listeners on $PORT: [$(listeners)]"
        say "system daemon: $(system_gone && echo retired || echo PRESENT)"
        [ -f "$STATE/current.plist" ] && say "current: $(field "$STATE/current.plist" WorkingDirectory)"
        [ -f "$STATE/previous.plist" ] && say "previous: $(field "$STATE/previous.plist" WorkingDirectory)"
        exit 0 ;;
    start:1) switch "$STATE/com.omi-notes.server.2afefbb.plist" "$STATE/com.omi-notes.server.d4767d2.plist" ;;
    start:2) switch "$2" "" ;;
    deploy:2) [ -f "$STATE/current.plist" ] || { say "no current plist; use start"; exit 1; }
              cp "$STATE/current.plist" "$STATE/rollback.tmp"; switch "$2" "$STATE/rollback.tmp" ;;
    rollback:1) [ -f "$STATE/previous.plist" ] || { say "no previous plist"; exit 1; }
                cp "$STATE/current.plist" "$STATE/rollback.tmp"; switch "$STATE/previous.plist" "$STATE/rollback.tmp" ;;
    *) say "usage: user-service.sh status | start [PLIST] | deploy PLIST | rollback"; exit 1 ;;
esac
