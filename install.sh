#!/bin/sh
# IFNH installer — curl-pipe friendly:
#   curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/install.sh | sh
# Env overrides:
#   IFNH_REPO=<org>/<repo>   GitHub repo (see CHANGE ME below)
#   IFNH_PREFIX=<dir>        install dir (default ~/.local/bin)
#   IFNH_VERSION=<tag>       release tag (default: latest)
set -eu

# CHANGE ME once the repo is pushed, or export IFNH_REPO:
REPO="https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here"
PREFIX="${IFNH_PREFIX:-$HOME/.local/bin}"

# --- platform detection ---
arch=$(uname -m)
os=$(uname -s)
case "$arch" in
  x86_64|amd64) tarch="x86_64" ;;
  aarch64|arm64) tarch="aarch64" ;;
  *) echo "ifnh: unsupported architecture '$arch'" >&2; exit 1 ;;
esac
case "$os" in
  Linux) tos="linux" ;;
  Darwin) tos="macos" ;;
  *) echo "ifnh: unsupported OS '$os'" >&2; exit 1 ;;
esac

fetch() {
  # fetch <url> <outfile>
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget > /dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    echo "ifnh: need curl or wget to download" >&2
    exit 1
  fi
}

base="https://github.com/${REPO}/releases"
if [ "${IFNH_VERSION:-}" != "" ]; then
  dl="$base/download/${IFNH_VERSION}"
else
  dl="$base/latest/download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Prefer static musl builds on Linux (no glibc version coupling).
candidates=""
if [ "$tos" = "linux" ]; then
  candidates="${tarch}-linux-musl ${tarch}-linux-gnu"
else
  candidates="${tarch}-macos"
fi

installed=0
for target in $candidates; do
  url="$dl/ifnh-${target}.tar.gz"
  echo "ifnh: trying $url"
  if fetch "$url" "$tmp/ifnh.tar.gz" 2>/dev/null; then
    # Checksum verification when we can fetch the sum.
    if fetch "$url.sha256" "$tmp/ifnh.tar.gz.sha256" 2>/dev/null; then
      if command -v sha256sum > /dev/null 2>&1; then
        (cd "$tmp" && echo "$(cat ifnh.tar.gz.sha256 | awk '{print $1}')  ifnh.tar.gz" | sha256sum -c - > /dev/null 2>&1) || {
          echo "ifnh: checksum mismatch for $target" >&2
          exit 1
        }
      fi
    fi
    tar -xzf "$tmp/ifnh.tar.gz" -C "$tmp"
    mkdir -p "$PREFIX"
    install -m 0755 "$tmp/ifnh" "$PREFIX/ifnh"
    installed=1
    echo "ifnh: installed $target build -> $PREFIX/ifnh"
    break
  fi
done

if [ "$installed" != 1 ]; then
  echo "ifnh: no release artifact found (checked: $candidates)" >&2
  echo "      have you pushed a tag? see .github/workflows/release.yml" >&2
  exit 1
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "ifnh: NOTE '$PREFIX' is not on your PATH" >&2
     echo "      add:  export PATH=\"$PREFIX:\$PATH\"  (to ~/.bashrc or ~/.zshrc)" >&2 ;;
esac

"$PREFIX/ifnh" --version
echo "ifnh: next steps — 'cd your/project && ifnh init && ifnh doctor'"
