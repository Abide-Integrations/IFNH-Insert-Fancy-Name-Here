#!/bin/sh
# Render the Homebrew formula for a release (ACTIVE_PLAN F-05).
#   scripts/bump-homebrew.sh [<version>] [--dist-dir <dir>] [--out <dir>] [--push]
# <version> defaults to scripts/check-version.sh --print (leading v optional).
# Hashes come from the published .sha256 files (scripts/release-sha256.sh): from
# --dist-dir if given, else from the GitHub release (IFNH_RELEASE_BASE_URL
# overrides the download base, file:// works). Default is a dry run: writes
# <out>/Formula/ifnh.rb (out defaults to dist) and touches nothing else.
# --push (owner-side) additionally commits that file to
# Abide-Integrations/homebrew-ifnh using $HOMEBREW_TAP_TOKEN; the token is only
# passed as an HTTP header, never written to the clone's config or printed.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
ver=""
dist=""
out="dist"
push=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dist-dir) [ $# -ge 2 ] || { echo "bump-homebrew: --dist-dir needs a value" >&2; exit 2; }; dist="$2"; shift ;;
    --out) [ $# -ge 2 ] || { echo "bump-homebrew: --out needs a value" >&2; exit 2; }; out="$2"; shift ;;
    --push) push=1 ;;
    -*) echo "bump-homebrew: unknown argument '$1'" >&2; exit 2 ;;
    *) ver="${1#v}" ;;
  esac
  shift
done
[ -n "$ver" ] || ver=$("$root/scripts/check-version.sh" --print)
sha() { "$root/scripts/release-sha256.sh" "$ver" "$1" ${dist:+"$dist"}; }

# Assigned first so a missing/bad .sha256 aborts (set -e ignores failures inside sed's arguments).
mac_arm=$(sha macos-aarch64)
mac_x64=$(sha macos-x86_64)
lin_arm=$(sha linux-aarch64-musl)
lin_x64=$(sha linux-x86_64-musl)
mkdir -p "$out/Formula"
sed -e "s/@VERSION@/$ver/" \
  -e "s/@SHA_MACOS_AARCH64@/$mac_arm/" \
  -e "s/@SHA_MACOS_X86_64@/$mac_x64/" \
  -e "s/@SHA_LINUX_AARCH64@/$lin_arm/" \
  -e "s/@SHA_LINUX_X86_64@/$lin_x64/" \
  "$root/packaging/homebrew/Formula/ifnh.rb" > "$out/Formula/ifnh.rb"
echo "bump-homebrew: wrote $out/Formula/ifnh.rb for $ver" >&2

[ "$push" = 1 ] || exit 0
: "${HOMEBREW_TAP_TOKEN:?bump-homebrew: --push needs HOMEBREW_TAP_TOKEN}"
auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$HOMEBREW_TAP_TOKEN" | base64 | tr -d '\n')"
tap=$(mktemp -d)
trap 'rm -rf "$tap"' EXIT
git -c http.extraheader="$auth" clone --depth 1 https://github.com/Abide-Integrations/homebrew-ifnh.git "$tap"
mkdir -p "$tap/Formula"
cp "$out/Formula/ifnh.rb" "$tap/Formula/ifnh.rb"
cd "$tap"
git add Formula/ifnh.rb
git diff --cached --quiet && { echo "bump-homebrew: tap already at $ver" >&2; exit 0; }
git -c user.name="ifnh-release" -c user.email="noreply@users.noreply.github.com" commit -q -m "ifnh $ver"
git -c http.extraheader="$auth" push origin HEAD
