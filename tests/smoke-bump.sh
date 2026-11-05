#!/bin/sh
# Offline test for the packaging bump scripts (ACTIVE_PLAN F-05, F-08): renders
# each from a fake release dir of .sha256 files and checks that every hash lands,
# no @TOKEN@ is left, output is deterministic, and a missing/malformed .sha256
# aborts without writing output.
#   tests/smoke-bump.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

rel="$T/release"
mkdir -p "$rel"
i=0
for plat in macos-aarch64 macos-x86_64 linux-aarch64-musl linux-x86_64-musl; do
  i=$((i + 1))
  printf '%064d  ifnh-9.9.9-%s.tar.gz\n' "$i" "$plat" > "$rel/ifnh-9.9.9-$plat.tar.gz.sha256"
done

# --- Homebrew ------------------------------------------------------------------
"$root/scripts/bump-homebrew.sh" 9.9.9 --dist-dir "$rel" --out "$T/a" 2> /dev/null
f="$T/a/Formula/ifnh.rb"
grep -q 'version "9.9.9"' "$f" || fail "brew: version missing"
for n in 1 2 3 4; do
  grep -q "$(printf '%064d' "$n")" "$f" || fail "brew: hash $n missing"
done
grep -E '@[A-Z_0-9]+@' "$f" > /dev/null && fail "brew: unfilled token"
"$root/scripts/bump-homebrew.sh" v9.9.9 --dist-dir "$rel" --out "$T/b" 2> /dev/null
cmp "$f" "$T/b/Formula/ifnh.rb" || fail "brew: not deterministic"
ok "homebrew: render, hashes, determinism"

rm "$rel/ifnh-9.9.9-macos-x86_64.tar.gz.sha256"
if "$root/scripts/bump-homebrew.sh" 9.9.9 --dist-dir "$rel" --out "$T/c" 2> /dev/null; then fail "brew: missing .sha256 accepted"; fi
[ ! -e "$T/c/Formula/ifnh.rb" ] || fail "brew: wrote output despite failure"
echo "zz  ifnh-9.9.9-macos-x86_64.tar.gz" > "$rel/ifnh-9.9.9-macos-x86_64.tar.gz.sha256"
if "$root/scripts/bump-homebrew.sh" 9.9.9 --dist-dir "$rel" --out "$T/c" 2> /dev/null; then fail "brew: bad digest accepted"; fi
ok "homebrew: missing/bad .sha256 aborts"

# --- AUR and Nix (fresh, valid fake release) ------------------------------------
rel="$T/release2"
mkdir -p "$rel"
i=0
for plat in macos-aarch64 macos-x86_64 linux-aarch64-musl linux-x86_64-musl; do
  i=$((i + 1))
  printf '%064d  ifnh-9.9.9-%s.tar.gz\n' "$i" "$plat" > "$rel/ifnh-9.9.9-$plat.tar.gz.sha256"
done

"$root/scripts/bump-aur.sh" 9.9.9 --dist-dir "$rel" --out "$T/aur" 2> /dev/null
grep -q '^pkgver=9.9.9$' "$T/aur/PKGBUILD" || fail "aur: pkgver"
grep -q "^sha256sums_x86_64=('$(printf '%064d' 4)')$" "$T/aur/PKGBUILD" || fail "aur: x86_64 hash"
grep -q "^sha256sums_aarch64=('$(printf '%064d' 3)')$" "$T/aur/PKGBUILD" || fail "aur: aarch64 hash"
grep -q "sha256sums_x86_64 = $(printf '%064d' 4)$" "$T/aur/.SRCINFO" || fail "aur: .SRCINFO x86_64 hash"
grep -q 'pkgver = 9.9.9$' "$T/aur/.SRCINFO" || fail "aur: .SRCINFO pkgver"
grep -q "^sha256sums.*SKIP" "$T/aur/PKGBUILD" && fail "aur: SKIP left in PKGBUILD"
ok "aur: PKGBUILD and .SRCINFO"

"$root/scripts/bump-nix.sh" 9.9.9 --dist-dir "$rel" --out "$T/nix/artifacts.nix" 2> /dev/null
grep -q 'version = "9.9.9";' "$T/nix/artifacts.nix" || fail "nix: version"
grep -q "x86_64-darwin = { suffix = \"macos-x86_64\"; sha256 = \"$(printf '%064d' 2)\"" "$T/nix/artifacts.nix" || fail "nix: darwin hash"
grep -q PLACEHOLDER "$T/nix/artifacts.nix" && fail "nix: placeholder note on a real render"
"$root/scripts/bump-nix.sh" --placeholder --out "$T/nix/p.nix" 2> /dev/null
grep -q PLACEHOLDER "$T/nix/p.nix" || fail "nix: placeholder note missing"
ok "nix: artifacts.nix and placeholder"

rm "$rel/ifnh-9.9.9-linux-aarch64-musl.tar.gz.sha256"
if "$root/scripts/bump-aur.sh" 9.9.9 --dist-dir "$rel" --out "$T/aur2" 2> /dev/null; then fail "aur: missing .sha256 accepted"; fi
[ ! -e "$T/aur2/PKGBUILD" ] || fail "aur: wrote output despite failure"
if "$root/scripts/bump-nix.sh" 9.9.9 --dist-dir "$rel" --out "$T/nix/q.nix" 2> /dev/null; then fail "nix: missing .sha256 accepted"; fi
[ ! -e "$T/nix/q.nix" ] || fail "nix: wrote output despite failure"
ok "aur/nix: missing .sha256 aborts"
