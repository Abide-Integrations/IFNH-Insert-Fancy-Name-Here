#!/bin/sh
# Print the sha256 of one published release tarball (ACTIVE_PLAN F-05/F-08);
# shared by bump-homebrew.sh, bump-aur.sh and bump-nix.sh.
#   scripts/release-sha256.sh <version> <platform> [<dist-dir>]
# <platform> is the middle of the F-01 name, e.g. linux-x86_64-musl, macos-aarch64.
# The hash comes from the published ifnh-<version>-<platform>.tar.gz.sha256, read
# from <dist-dir> if given, else fetched from
# ${IFNH_RELEASE_BASE_URL:-https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download}/v<version>/
# (IFNH_RELEASE_BASE_URL may be a file:// URL). The tarball itself is not downloaded.
set -eu

ver="${1:?usage: release-sha256.sh <version> <platform> [<dist-dir>]}"
plat="${2:?usage: release-sha256.sh <version> <platform> [<dist-dir>]}"
dist="${3:-}"
ver="${ver#v}"
file="ifnh-$ver-$plat.tar.gz"
base="${IFNH_RELEASE_BASE_URL:-https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download}"

if [ -n "$dist" ]; then
  line=$(cat "$dist/$file.sha256")
else
  line=$(curl -fsSL "$base/v$ver/$file.sha256")
fi
hash=$(printf '%s' "$line" | awk '{print $1}')
name=$(printf '%s' "$line" | awk '{print $2}')
[ "$name" = "$file" ] || { echo "release-sha256: $file.sha256 names '$name', want '$file'" >&2; exit 1; }
case "$hash" in
  *[!0-9a-f]*) echo "release-sha256: $file.sha256 is not a hex digest" >&2; exit 1 ;;
esac
[ "${#hash}" = 64 ] || { echo "release-sha256: $file.sha256 is not 64 hex chars" >&2; exit 1; }
echo "$hash"
