#!/bin/sh
# Release version consistency (ACTIVE_PLAN F-01): src/version.zig is the
# source of truth; build.zig.zon `.version` (and a release tag) must match it.
#   scripts/check-version.sh               compare version.zig with build.zig.zon
#   scripts/check-version.sh --tag v0.1.7  also compare the tag (leading v optional)
#   scripts/check-version.sh --print       print only the version (still checked)
# Env: IFNH_SRC_DIR=<dir> reads <dir>/src/version.zig and <dir>/build.zig.zon
# instead of the repo this script lives in (used to test the failure path).
set -eu

root="${IFNH_SRC_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
tag=""
print_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) [ $# -ge 2 ] || { echo "check-version: --tag needs a value" >&2; exit 2; }; tag="$2"; shift ;;
    --print) print_only=1 ;;
    *) echo "check-version: unknown argument '$1' (use --tag <tag> or --print)" >&2; exit 2 ;;
  esac
  shift
done

zig_ver=$(sed -n 's/^pub const version = "\([^"]*\)";.*/\1/p' "$root/src/version.zig" 2>/dev/null | head -n 1)
zon_ver=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",.*/\1/p' "$root/build.zig.zon" 2>/dev/null | head -n 1)

[ -n "$zig_ver" ] || { echo "check-version: cannot read version from $root/src/version.zig" >&2; exit 1; }
[ -n "$zon_ver" ] || { echo "check-version: cannot read .version from $root/build.zig.zon" >&2; exit 1; }
[ "$zig_ver" = "$zon_ver" ] || { echo "check-version: mismatch: src/version.zig=$zig_ver build.zig.zon=$zon_ver" >&2; exit 1; }
if [ -n "$tag" ] && [ "${tag#v}" != "$zig_ver" ]; then
  echo "check-version: mismatch: tag=$tag (want v$zig_ver)" >&2
  exit 1
fi

if [ "$print_only" = 1 ]; then echo "$zig_ver"; else echo "version $zig_ver ok"; fi
