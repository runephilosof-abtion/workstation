#!/usr/bin/env bash
# claude-sessions against a fake /proc (CLAUDE_SESSIONS_PROC), a fake Claude
# Code directory and stubbed gnome-terminal/notify-send/layout helper: no real
# process, terminal window or notification is involved.
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

REPO_ROOT=$(cd .. && pwd -P)
SCRIPT=$REPO_ROOT/roles/claude-code/files/claude-sessions
FIXTURES=$(pwd -P)/fixtures/bin

A=aaaaaaaa-0000-4000-8000-000000000001
B=bbbbbbbb-0000-4000-8000-000000000002
C=cccccccc-0000-4000-8000-000000000003
D=dddddddd-0000-4000-8000-000000000004

setup() {
  SANDBOX=$(mktemp -d)
  export HOME=$SANDBOX/home
  export XDG_STATE_HOME=$SANDBOX/state
  export CLAUDE_CONFIG_DIR=$SANDBOX/claude
  export CLAUDE_SESSIONS_PROC=$SANDBOX/proc
  export STUB_LOG=$SANDBOX/stub.log
  export PATH=$FIXTURES:$PATH
  unset STUB_LAYOUT STUB_NOTIFY_ACTION
  W=$SANDBOX/work
  mkdir -p "$HOME" "$W" "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/p"
  : > "$STUB_LOG"
  boot first-boot
}

teardown() { rm -rf "$SANDBOX"; }

boot() {
  mkdir -p "$CLAUDE_SESSIONS_PROC/sys/kernel/random"
  echo "$1" > "$CLAUDE_SESSIONS_PROC/sys/kernel/random/boot_id"
}

# proc PID NAME PARENT START [ARGV...]: a running process, as /proc shows it.
proc() {
  local pid=$1 name=$2 parent=$3 start=$4
  shift 4
  mkdir -p "$CLAUDE_SESSIONS_PROC/$pid"
  {
    printf '%s (%s) S %s' "$pid" "$name" "$parent"
    printf ' 0%.0s' {1..17}
    printf ' %s 0 0\n' "$start"
  } > "$CLAUDE_SESSIONS_PROC/$pid/stat"
  printf '%s\0' "$@" > "$CLAUDE_SESSIONS_PROC/$pid/cmdline"
}

# terminal [START]: gnome-terminal-server, pid 100; another START is another instance.
terminal() { proc 100 gnome-terminal- 1 "${1:-1000}" /usr/libexec/gnome-terminal-server; }

# Everything in the terminal dies with it: reboot, logout or desktop crash.
crash() { rm -rf "$CLAUDE_SESSIONS_PROC"/[0-9]*; }

transcript() {
  local id=$1 started_in=$2 title=$3
  mkdir -p "$started_in"
  printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n{"type":"ai-title","aiTitle":"%s","sessionId":"%s"}\n' \
    "$started_in" "$id" "$title" "$id" > "$CLAUDE_CONFIG_DIR/projects/p/$id.jsonl"
}

# session PID ID DIR TITLE: a session Claude Code has registered, in a terminal tab.
session() {
  local pid=$1 id=$2 dir=$3 title=$4
  proc "$pid" claude 100 "5$pid" claude
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"5%s","kind":"interactive","name":"auto-%s"}\n' \
    "$pid" "$id" "$dir" "$pid" "$pid" > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
  transcript "$id" "$dir" "$title"
}

three_sessions_in_two_windows() {
  terminal
  session 301 $A "$W/a" "Fix the build"
  session 302 $B "$W/b" "Write docs"
  session 303 $C "$W/c" "Upgrade Rails"
  export STUB_LAYOUT='{"windows":[["✳ Fix the build","◐ Write docs"],["✳ Upgrade Rails"]]}'
}

windows_opened() { grep -c '^gnome-terminal --window' "$STUB_LOG"; }

echo "restore: windows and tabs come back the way they were"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
OUT=$("$SCRIPT" restore --yes 2>&1); STATUS=$?
LOG=$(cat "$STUB_LOG")
assert_eq "exits zero" 0 "$STATUS"
assert_eq "opens two windows" 2 "$(windows_opened)"
assert_contains "first window holds both its tabs, in order" "$LOG" \
  "gnome-terminal --window --working-directory=$W/a -- $SCRIPT _tab $W/a $A $W/b $B"
assert_contains "second window holds the third session" "$LOG" \
  "gnome-terminal --window --working-directory=$W/c -- $SCRIPT _tab $W/c $C"
assert_contains "lists what it restores" "$OUT" "Write docs"
teardown

echo "restore: nothing to restore while the terminal is still running"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
OUT=$("$SCRIPT" restore --yes 2>&1); STATUS=$?
assert_eq "exits zero" 0 "$STATUS"
assert_contains "says so" "$OUT" "No snapshot to restore"
assert_eq "opens nothing" 0 "$(windows_opened)"
teardown

echo "restore: a reboot counts even when the terminal's pid and start time repeat"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
boot second-boot
terminal
"$SCRIPT" restore --yes > /dev/null 2>&1
assert_eq "restores the snapshot from the earlier boot" 2 "$(windows_opened)"
teardown

echo "snapshot: a session closed by hand does not come back"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
rm -rf "$CLAUDE_SESSIONS_PROC/302"
"$SCRIPT" snapshot
crash
"$SCRIPT" restore --yes > /dev/null 2>&1
LOG=$(cat "$STUB_LOG")
assert_not_contains "closed session is left out" "$LOG" "$B"
assert_contains "its sibling tab still opens" "$LOG" "_tab $W/a $A"
teardown

echo "snapshot: runs after the crash keep the last snapshot from before it"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
"$SCRIPT" snapshot
terminal 2000
session 401 $D "$W/d" "New work"
"$SCRIPT" snapshot
"$SCRIPT" snapshot
OUT=$("$SCRIPT" restore --yes 2>&1)
LOG=$(cat "$STUB_LOG")
assert_eq "still restores the two windows from before" 2 "$(windows_opened)"
assert_contains "with all three sessions" "$LOG$LOG" "$A $W/b $B"
assert_not_contains "and not the session started since" "$LOG" "$D"
teardown

echo "restore: sessions that are open again are skipped"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
terminal 2000
session 501 $A "$W/a" "Fix the build"
OUT=$("$SCRIPT" restore --yes 2>&1)
LOG=$(cat "$STUB_LOG")
assert_contains "reports the skip" "$OUT" "skipped: Fix the build - already open"
assert_contains "window opens with the remaining tab" "$LOG" "_tab $W/b $B"
assert_not_contains "open session is not started twice" "$LOG" "$A"
teardown

echo "restore: a session whose directory is gone is skipped"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
rmdir "$W/c"
OUT=$("$SCRIPT" restore --yes 2>&1)
assert_contains "reports the skip" "$OUT" "skipped: Upgrade Rails - $W/c no longer exists"
assert_eq "opens the other window" 1 "$(windows_opened)"
teardown

echo "snapshot: sessions whose tab is not found share one extra window"
setup
three_sessions_in_two_windows
export STUB_LAYOUT='{"windows":[["✳ Fix the build"],["bash"]]}'
"$SCRIPT" snapshot
crash
"$SCRIPT" restore --yes > /dev/null 2>&1
LOG=$(cat "$STUB_LOG")
assert_contains "the found tab keeps its window" "$LOG" "-- $SCRIPT _tab $W/a $A"$'\n'
assert_contains "the others share a window" "$LOG" "-- $SCRIPT _tab $W/b $B $W/c $C"
teardown

echo "snapshot: without a readable layout every session still comes back"
setup
three_sessions_in_two_windows
unset STUB_LAYOUT
"$SCRIPT" snapshot
crash
"$SCRIPT" restore --yes > /dev/null 2>&1
assert_contains "as tabs of one window" "$(cat "$STUB_LOG")" "_tab $W/a $A $W/b $B $W/c $C"
teardown

echo "snapshot: same-titled sessions keep the shape of the layout"
setup
terminal
session 301 $A "$W/a" "Claude Code"
session 302 $B "$W/b" "Claude Code"
export STUB_LAYOUT='{"windows":[["✳ Claude Code"],["✳ Claude Code"]]}'
"$SCRIPT" snapshot
crash
"$SCRIPT" restore --yes > /dev/null 2>&1
assert_eq "one window each" 2 "$(windows_opened)"
teardown

echo "snapshot: a resumed session that has not registered yet is recorded"
setup
three_sessions_in_two_windows
proc 304 claude 100 5304 claude --resume $D
ln -s "$W/d" "$CLAUDE_SESSIONS_PROC/304/cwd"
transcript $D "$W/d" "Tune the queue"
export STUB_LAYOUT='{"windows":[["✳ Fix the build","◐ Write docs"],["✳ Upgrade Rails","✳ Tune the queue"]]}'
"$SCRIPT" snapshot
crash
"$SCRIPT" restore --yes > /dev/null 2>&1
assert_contains "in the window its tab was in" "$(cat "$STUB_LOG")" "_tab $W/c $C $W/d $D"
teardown

echo "snapshot: a session that moved into a worktree resumes from where it started"
setup
terminal
session 301 $A "$W/a/.claude/worktrees/x" "Fix the build"
transcript $A "$W/a" "Fix the build"
export STUB_LAYOUT='{"windows":[["✳ Fix the build"]]}'
"$SCRIPT" snapshot
crash
"$SCRIPT" restore --yes > /dev/null 2>&1
assert_contains "uses the start directory" "$(cat "$STUB_LOG")" "--working-directory=$W/a -- $SCRIPT _tab $W/a $A"
teardown

echo "restore: asks first, and refuses to guess without a terminal"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
OUT=$("$SCRIPT" restore < /dev/null 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_contains "points at --yes" "$OUT" "--yes"
assert_eq "opens nothing" 0 "$(windows_opened)"
teardown

echo "list: shows the snapshots that can be restored"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
OUT=$("$SCRIPT" list 2>&1)
assert_contains "with their size" "$OUT" "3 sessions in 2 windows"
teardown

echo "_tab: opens the next tab from inside the window, then becomes the session"
setup
mkdir -p "$W/a" "$W/b"
SHELL=$FIXTURES/fake-shell "$SCRIPT" _tab "$W/a" $A "$W/b" $B
LOG=$(cat "$STUB_LOG")
assert_contains "passes the remaining tabs on" "$LOG" \
  "gnome-terminal --tab --working-directory=$W/b -- $SCRIPT _tab $W/b $B"
assert_contains "resumes its own session in an interactive shell" "$LOG" \
  "shell -ic claude --resume $A; exec $FIXTURES/fake-shell"
teardown

echo "_tab: refuses anything that is not a session id"
setup
mkdir -p "$W/a"
OUT=$(SHELL=$FIXTURES/fake-shell "$SCRIPT" _tab "$W/a" 'x; touch /tmp/pwned' 2>&1); STATUS=$?
assert_eq "exits non-zero" 1 "$STATUS"
assert_eq "starts no shell" "" "$(cat "$STUB_LOG")"
teardown

echo "offer: the Restore button opens the windows"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
STUB_NOTIFY_ACTION=restore "$SCRIPT" offer
LOG=$(cat "$STUB_LOG")
assert_contains "notifies with a Restore button" "$LOG" "--action=restore=Restore"
assert_contains "says how much there is" "$LOG" "3 sessions in 2 windows"
assert_eq "opens the windows" 2 "$(windows_opened)"
teardown

echo "offer: a dismissed notification opens nothing, and is not shown again"
setup
three_sessions_in_two_windows
"$SCRIPT" snapshot
crash
"$SCRIPT" offer
"$SCRIPT" offer
assert_eq "notifies once" 1 "$(grep -c '^notify-send' "$STUB_LOG")"
assert_eq "opens nothing" 0 "$(windows_opened)"
OUT=$("$SCRIPT" restore --yes 2>&1)
assert_eq "restore still works afterwards" 2 "$(windows_opened)"
teardown

echo "offer: stays quiet when there is nothing to restore"
setup
"$SCRIPT" offer
assert_eq "no notification" "" "$(cat "$STUB_LOG")"
teardown

finish
