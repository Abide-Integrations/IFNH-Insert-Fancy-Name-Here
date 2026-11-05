#!/bin/sh
# IFNH installer: copies a local build (or downloads a release) to ~/.local/bin.
# Usage:
#   scripts/install.sh                 # install ./zig-out/bin/ifnh if present
#   scripts/install.sh --download      # fetch latest release for this platform
#   scripts/install.sh --version v0.1.0 --download
set -e
prefix="${IFNH_PREFIX:-$HOME/.local/bin}"
repo="${IFNH_REPO:-Abide-Integrations/IFNH-Insert-Fancy-Name-Here}"

need_download=0
version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --download) need_download=1 ;;
    --version) version="${2:?--version needs a tag}"; shift ;;
  esac
  shift
done

# A release download is the root install.sh's job (artifact names, checksum,
# package-manager check live there).
if [ "$need_download" = 1 ]; then
  exec env IFNH_PREFIX="$prefix" IFNH_REPO="$repo" IFNH_VERSION="$version" sh "$(dirname "$0")/../install.sh"
fi

mkdir -p "$prefix"

src="./zig-out/bin/ifnh"
if [ ! -x "$src" ]; then
  echo "no local build at $src — run 'zig build -Doptimize=ReleaseSafe' or use --download"
  exit 1
fi

install -m 0755 "$src" "$prefix/ifnh"
echo "installed: $prefix/ifnh"
case ":$PATH:" in
  *":$prefix:"*) ;;
  *) echo "note: $prefix is not on your PATH — add 'export PATH=\"$prefix:\$PATH\"' to your shell profile" ;;
esac
"$prefix/ifnh" --version
