#!/bin/sh
# M0-T39: kill -9 resilience — start a session, hard-kill the process,
# verify resume recovers cleanly (events intact, torn tail tolerated).
set -e
BIN=$(readlink -f "${1:-./zig-out/bin/ifnh}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q .

# Start a session and kill it hard mid-flight.
printf 'hello there\n' | "$BIN" > /dev/null 2>&1 &
pid=$!
sleep 1
kill -9 $pid 2>/dev/null || true
wait $pid 2>/dev/null || true

# Events written before the kill must exist.
events=$(find .ifnh/sessions -name events.jsonl | head -1)
test -n "$events" || { echo "FAIL: no events.jsonl after kill -9"; exit 1; }

# Resume must open the session without error and the torn-tail scan
# must recover position.
sid=$("$BIN" sessions list | awk '{print $1}' | head -1)
test -n "$sid" || { echo "FAIL: no session listed after kill -9"; exit 1; }
printf '/quit\n' | "$BIN" resume "$sid" > /dev/null 2>&1 || { echo "FAIL: resume errored"; exit 1; }

# Journal recovery ran at open (rollback of incomplete groups).
test -f ".ifnh/sessions/$sid/journal.jsonl" || { echo "FAIL: no journal"; exit 1; }

echo "kill-9 resilience: OK (session $sid survived, resume clean)"
