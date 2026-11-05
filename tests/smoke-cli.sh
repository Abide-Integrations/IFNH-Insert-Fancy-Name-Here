#!/bin/sh
# Smoke test for the packaging-surface subcommands (ACTIVE_PLAN F-02/F-04)
# against a built binary. HOME and XDG_* point at an empty temp dir, which must
# still be empty afterwards: none of these commands may write user state.
#   tests/smoke-cli.sh [path-to-ifnh]   (default ./zig-out/bin/ifnh)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
bin="${1:-$root/zig-out/bin/ifnh}"
[ -x "$bin" ] || { echo "smoke-cli: $bin not built (zig build)" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
mkdir "$T/home" "$T/cwd"
ifnh() { (cd "$T/cwd" && env HOME="$T/home" XDG_CONFIG_HOME="$T/home/xdg" XDG_STATE_HOME="$T/home/state" "$bin" "$@"); }
rc_of() { rc=0; "$@" > "$T/out" 2> "$T/err" || rc=$?; }

want=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' "$root/src/version.zig")

rc_of ifnh version
[ "$rc" = 0 ] && [ "$(cat "$T/out")" = "ifnh $want" ] || fail "version"
rc_of ifnh -V
[ "$rc" = 0 ] && [ "$(cat "$T/out")" = "ifnh $want" ] || fail "-V"
ok "version and -V print only 'ifnh $want'"

rc_of ifnh version --verbose
[ "$rc" = 0 ] || fail "version --verbose exited $rc"
[ "$(wc -l < "$T/out")" -eq 4 ] || fail "version --verbose is not four lines"
sed -n 1p "$T/out" | grep -qx "ifnh $want" || fail "line 1"
sed -n 2p "$T/out" | grep -Eq '^commit: [0-9a-f]{4,40}$|^commit: unknown$' || fail "line 2"
sed -n 3p "$T/out" | grep -Eq '^target: [a-z0-9_]+-[a-z]+(-[a-z0-9]+)?$' || fail "line 3"
sed -n 4p "$T/out" | grep -Eq '^mode: (Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)$' || fail "line 4"
ok "version --verbose: four documented lines"

rc_of ifnh version --bogus
[ "$rc" = 2 ] && [ ! -s "$T/out" ] && [ -s "$T/err" ] || fail "version --bogus must be a usage error on stderr"
ok "version with another argument: exit 2"

for sh in bash zsh fish; do
  rc_of ifnh completions "$sh"
  [ "$rc" = 0 ] && [ ! -s "$T/err" ] && [ -s "$T/out" ] || fail "completions $sh"
  for sub in init config sessions resume fork cleanup ask doctor serve memory debug-bundle session replay completions help version; do
    grep -q "$sub" "$T/out" || fail "completions $sh lacks $sub"
  done
  grep -q __sandbox-exec "$T/out" && fail "completions $sh leaks the hidden subcommand"
  [ "$sh" != bash ] || bash -n "$T/out" || fail "bash completions do not parse"
done
ok "completions bash|zsh|fish: stdout only, every subcommand, bash -n clean"

rc_of ifnh completions
[ "$rc" = 2 ] && [ ! -s "$T/out" ] && grep -q 'usage: ifnh completions' "$T/err" || fail "completions with no shell"
rc_of ifnh completions powershell
[ "$rc" = 2 ] && [ ! -s "$T/out" ] && grep -q 'usage: ifnh completions' "$T/err" || fail "completions with unknown shell"
ok "completions with no/unknown shell: exit 2, message on stderr"

[ -z "$(ls -A "$T/home")$(ls -A "$T/cwd")" ] || fail "commands created files"
ok "HOME, XDG and cwd stayed empty"
echo "smoke-cli: all checks passed"
