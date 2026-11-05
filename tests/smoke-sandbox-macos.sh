#!/bin/sh
# E-04/E-09 smoke: the OS sandbox through the real binary. Written for the
# macOS (Seatbelt) job, but it checks whatever backend `ifnh doctor` reports,
# so it also runs on Linux (bwrap or Landlock).
#   (a) `ifnh doctor` prints the `sandbox:` line (backend must be seatbelt on macOS);
#   (b) with sandbox.mode=required, a model-issued write inside the workspace
#       works and a write outside it is denied (scripts/fake_provider.py --mode tool).
# Prints SKIP and exits 0 when no backend is available. Needs python3.
set -e
BIN=$(readlink -f "${1:-./zig-out/bin/ifnh}")
HERE=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
outside="$HERE/.smoke-sandbox-outside-$$"
srv=
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; rm -rf "$work" "$outside"; }
trap cleanup EXIT
mkdir -p "$outside"
cd "$work"
git init -q .
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$HOME"
export IFNH_SANDBOX__MODE=required

line=$("$BIN" doctor 2>&1 | grep '^  sandbox: ' | sed 's/^  //') || true
[ -n "$line" ] || { echo "FAIL: ifnh doctor printed no sandbox line"; exit 1; }
echo "$line"
backend=$(echo "$line" | sed 's/^sandbox: \([a-z]*\) .*/\1/')
if [ "$backend" = none ]; then echo "SKIP: no sandbox backend on this host"; exit 0; fi
if [ "$(uname)" = Darwin ] && [ "$backend" != seatbelt ]; then echo "FAIL: expected seatbelt on macOS, got $backend"; exit 1; fi
if [ "$backend" = seatbelt ] && [ ! -x /usr/bin/sandbox-exec ]; then echo "SKIP: sandbox-exec missing"; exit 0; fi

export IFNH_MODEL__MODEL=smoke-model OPENAI_API_KEY=smoke
run_tool() { # $1 = bash command the fake model issues
  python3 "$HERE/scripts/fake_provider.py" --mode tool --bash-command "$1" --port-file "$work/port" &
  srv=$!
  i=0
  while [ ! -s "$work/port" ]; do
    i=$((i + 1)); [ $i -gt 100 ] && { echo "FAIL: fake provider did not start"; exit 1; }
    sleep 0.1
  done
  IFNH_MODEL__BASE_URL="http://$(cat "$work/port")" "$BIN" ask --yes --json -p "go" > "$work/out" 2>&1 || true
  kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
  srv=; rm -f "$work/port"
}

run_tool "mkdir -p .ifnh && touch .ifnh/allowed.txt"
[ -e .ifnh/allowed.txt ] || { echo "FAIL: write inside the workspace was blocked"; cat "$work/out"; exit 1; }

run_tool "touch '$outside/denied.txt'"
if [ -e "$outside/denied.txt" ]; then echo "FAIL: write outside the workspace succeeded"; exit 1; fi
grep -q '"phase":"end","ok":false' "$work/out" || { echo "FAIL: the denied write was not reported as a failed tool call"; cat "$work/out"; exit 1; }

echo "sandbox smoke ($backend): OK"
