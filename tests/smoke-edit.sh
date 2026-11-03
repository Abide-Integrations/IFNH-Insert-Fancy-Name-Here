#!/bin/sh
# D-10 smoke: `edit` through the CLI changes the workspace file (not a copy
# under .ifnh/sessions/) and leaves the journal in the session directory.
# Needs python3 for scripts/fake_provider.py.
set -e
BIN=$(readlink -f "${1:-./zig-out/bin/ifnh}")
HERE=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'kill $srv 2>/dev/null; rm -rf "$work"' EXIT
cd "$work"
git init -q .
printf 'alpha\nbeta\ngamma\n' > smoke.txt

python3 "$HERE/scripts/fake_provider.py" --mode edit --port-file "$work/port" &
srv=$!
i=0
while [ ! -s "$work/port" ]; do
  i=$((i + 1)); [ $i -gt 100 ] && { echo "FAIL: fake provider did not start"; exit 1; }
  sleep 0.1
done

export IFNH_MODEL__MODEL=smoke-model OPENAI_API_KEY=smoke
export IFNH_MODEL__BASE_URL="http://$(cat "$work/port")"
"$BIN" ask --yes -p "change beta" > "$work/out" 2>&1 || { cat "$work/out"; echo "FAIL: ask exited non-zero"; exit 1; }

printf 'alpha\nBETA\ngamma\n' | cmp -s - smoke.txt || { echo "FAIL: smoke.txt not edited in the workspace"; cat smoke.txt; exit 1; }
if find .ifnh/sessions -name smoke.txt | grep -q .; then echo "FAIL: smoke.txt leaked into the session directory"; exit 1; fi
find .ifnh/sessions -name journal.jsonl | grep -q . || { echo "FAIL: no journal.jsonl in the session directory"; exit 1; }
echo "edit smoke: OK"
