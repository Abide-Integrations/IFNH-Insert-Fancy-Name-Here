#!/bin/sh
# IFNH installer: copies a local build (or downloads a release) to ~/.local/bin.
# Usage:
#   scripts/install.sh                 # install ./zig-out/bin/ifnh if present
#   scripts/install.sh --download      # fetch latest release for this platform
#   scripts/install.sh --version v0.1.0 --download
set -e
prefix="${IFNH_PREFIX:-$HOME/.local/bin}"
repo="${IFNH_REPO:-ifnh/ifnh}"   # set to <org>/<repo> when published

need_download=0
for arg in "$@"; do
  case "$arg" in
    --download) need_download=1 ;;
    --version) shift_ver=1 ;;
  esac
done

mkdir -p "$prefix"

arch=$(uname -m)
os=$(uname -s)
case "$arch" in x86_64) tarch="x86_64" ;; aarch64|arm64) tarch="aarch64" ;; *) echo "unsupported arch: $arch"; exit 1 ;; esac
case "$os" in Linux) tos="linux" ;; Darwin) tos="macos" ;; *) echo "unsupported os: $os"; exit 1 ;; esac
target="${tarch}-${tos}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ "$need_download" = 1 ]; then
  url="https://github.com/${repo}/releases/latest/download/ifnh-${target}.tar.gz"
  echo "downloading $url"
  curl -fsSL "$url" -o "$tmp/ifnh.tar.gz"
  tar -xzf "$tmp/ifnh.tar.gz" -C "$tmp"
  src="$tmp/ifnh"
else
  src="./zig-out/bin/ifnh"
  if [ ! -x "$src" ]; then
    echo "no local build at $src — run 'zig build -Doptimize=ReleaseSafe' or use --download"
    exit 1
  fi
fi

install -m 0755 "$src" "$prefix/ifnh"
echo "installed: $prefix/ifnh"
case ":$PATH:" in
  *":$prefix:"*) ;;
  *) echo "note: $prefix is not on your PATH — add 'export PATH=\"$prefix:\$PATH\"' to your shell profile" ;;
esac
"$prefix/ifnh" --version
