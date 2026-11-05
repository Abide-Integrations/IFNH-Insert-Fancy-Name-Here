#!/bin/sh
# Render the AUR PKGBUILD and .SRCINFO for a release (ACTIVE_PLAN F-08), the
# AUR counterpart of scripts/bump-homebrew.sh.
#   scripts/bump-aur.sh [<version>] [--dist-dir <dir>] [--out <dir>]
# <version> defaults to scripts/check-version.sh --print. Hashes come from the
# published .sha256 files (scripts/release-sha256.sh; --dist-dir or
# IFNH_RELEASE_BASE_URL as there). Writes <out>/PKGBUILD and <out>/.SRCINFO
# (out defaults to dist/aur) and nothing else: pushing to the AUR is manual.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
ver=""
dist=""
out="dist/aur"
while [ $# -gt 0 ]; do
  case "$1" in
    --dist-dir) [ $# -ge 2 ] || { echo "bump-aur: --dist-dir needs a value" >&2; exit 2; }; dist="$2"; shift ;;
    --out) [ $# -ge 2 ] || { echo "bump-aur: --out needs a value" >&2; exit 2; }; out="$2"; shift ;;
    -*) echo "bump-aur: unknown argument '$1'" >&2; exit 2 ;;
    *) ver="${1#v}" ;;
  esac
  shift
done
[ -n "$ver" ] || ver=$("$root/scripts/check-version.sh" --print)
sha() { "$root/scripts/release-sha256.sh" "$ver" "$1" ${dist:+"$dist"}; }

# Assigned first so a missing/bad .sha256 aborts (set -e ignores failures inside sed's arguments).
x64=$(sha linux-x86_64-musl)
arm=$(sha linux-aarch64-musl)
mkdir -p "$out"
sed -e "s/^pkgver=.*/pkgver=$ver/" \
  -e "s/^pkgrel=.*/pkgrel=1/" \
  -e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('$x64')/" \
  -e "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('$arm')/" \
  "$root/packaging/aur/PKGBUILD" > "$out/PKGBUILD"

# .SRCINFO is what `makepkg --printsrcinfo` prints for the PKGBUILD above (checked
# against it in an Arch container); written here so no Arch host is needed.
url="https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here"
cat > "$out/.SRCINFO" << EOF
pkgbase = ifnh-bin
	pkgdesc = Lightweight agentic coding harness (prebuilt static binary)
	pkgver = $ver
	pkgrel = 1
	url = $url
	arch = x86_64
	arch = aarch64
	license = MIT
	provides = ifnh
	conflicts = ifnh
	options = !strip
	options = !debug
	source_x86_64 = ifnh-bin-$ver-x86_64.tar.gz::$url/releases/download/v$ver/ifnh-$ver-linux-x86_64-musl.tar.gz
	sha256sums_x86_64 = $x64
	source_aarch64 = ifnh-bin-$ver-aarch64.tar.gz::$url/releases/download/v$ver/ifnh-$ver-linux-aarch64-musl.tar.gz
	sha256sums_aarch64 = $arm

pkgname = ifnh-bin
EOF
echo "bump-aur: wrote $out/PKGBUILD and $out/.SRCINFO for $ver" >&2
