#!/bin/sh
# IFNH installer — curl-pipe friendly:
#   curl -fsSL https://raw.githubusercontent.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/main/install.sh | sh
# Env overrides:
#   IFNH_REPO=<org>/<repo>   GitHub repo (see CHANGE ME below)
#   IFNH_PREFIX=<dir>        install dir (default ~/.local/bin); man page and
#                            completions go to <dir>/../share when writable
#   IFNH_VERSION=<tag>       release tag, with or without the leading v
#                            (default: the latest release)
#
# Artifacts are ifnh-<version>-<os>-<arch>[-musl|-gnu].tar.gz with a .sha256
# next to each (verified here; a mismatch aborts). Signatures (cosign keyless)
# are an optional manual check, see docs/USAGE.md "Release artifacts".
set -eu

# CHANGE ME once the repo is pushed, or export IFNH_REPO:
REPO="${IFNH_REPO:-Abide-Integrations/IFNH-Insert-Fancy-Name-Here}"
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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- version ---
tag="${IFNH_VERSION:-}"
if [ -z "$tag" ]; then
  if fetch "https://api.github.com/repos/${REPO}/releases/latest" "$tmp/latest.json" 2> /dev/null; then
    tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp/latest.json" | head -n 1)
  fi
  if [ -z "$tag" ]; then
    echo "ifnh: could not resolve the latest release; set IFNH_VERSION (for example IFNH_VERSION=v0.1.7)" >&2
    exit 1
  fi
fi
case "$tag" in v*) ver="${tag#v}" ;; *) ver="$tag"; tag="v$tag" ;; esac
dl="https://github.com/${REPO}/releases/download/${tag}"

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "ifnh: need sha256sum or shasum to verify the download" >&2
    exit 1
  fi
}

# Prefer static musl builds on Linux (no glibc version coupling).
if [ "$tos" = "linux" ]; then
  candidates="linux-${tarch}-musl linux-${tarch}-gnu"
else
  candidates="macos-${tarch}"
fi

installed=0
for plat in $candidates; do
  name="ifnh-${ver}-${plat}"
  url="$dl/$name.tar.gz"
  echo "ifnh: trying $url"
  if fetch "$url" "$tmp/ifnh.tar.gz" 2> /dev/null; then
    fetch "$url.sha256" "$tmp/ifnh.tar.gz.sha256" 2> /dev/null || {
      echo "ifnh: no checksum published for $name.tar.gz; refusing to install" >&2
      exit 1
    }
    want=$(awk '{print $1}' "$tmp/ifnh.tar.gz.sha256")
    [ "$(sha256_of "$tmp/ifnh.tar.gz")" = "$want" ] || {
      echo "ifnh: checksum mismatch for $name.tar.gz" >&2
      exit 1
    }
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/ifnh.tar.gz" -C "$tmp/x"
    src="$tmp/x/$name"
    [ -f "$src/ifnh" ] || { echo "ifnh: $name.tar.gz has no ifnh binary" >&2; exit 1; }
    mkdir -p "$PREFIX"
    install -m 0755 "$src/ifnh" "$PREFIX/ifnh"
    installed=1
    echo "ifnh: installed $plat build -> $PREFIX/ifnh"
    break
  fi
done

if [ "$installed" != 1 ]; then
  echo "ifnh: no release artifact found for ${tag} (checked: $candidates)" >&2
  echo "      have you pushed a tag? see .github/workflows/release.yml" >&2
  exit 1
fi

# Man page and completions: <prefix>/../share, only where writable.
share="$(dirname "$PREFIX")/share"
put_share() {
  # put_share <file in the tarball, relative to share/> ; quiet when not possible
  [ -f "$src/share/$1" ] || return 0
  d="$share/$(dirname "$1")"
  if mkdir -p "$d" 2> /dev/null && [ -w "$d" ]; then
    install -m 0644 "$src/share/$1" "$share/$1" 2> /dev/null || true
  fi
}
put_share man/man1/ifnh.1
put_share bash-completion/completions/ifnh
put_share zsh/site-functions/_ifnh
put_share fish/vendor_completions.d/ifnh.fish

# Companion uninstaller (k3s pattern): installed next to the binary.
cat > "$tmp/ifnh-uninstall.sh" <<'UNINSTALL'
#!/bin/sh
# IFNH uninstaller: removes the binary and runtime state.
#   ifnh-uninstall.sh          keep ~/.config/ifnh (config + API keys)
#   ifnh-uninstall.sh --purge  also delete ~/.config/ifnh
# Project-local .ifnh/ directories are never touched.
set -eu
PREFIX="${IFNH_PREFIX:-$HOME/.local/bin}"
SHARE="$(dirname "$PREFIX")/share"
CONFIG_DIR="$HOME/.config/ifnh"
STATE_DIR="$HOME/.local/state/ifnh"
purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    *) echo "ifnh-uninstall: unknown option '$arg' (use --purge)" >&2; exit 1 ;;
  esac
done
echo "ifnh uninstall:"
removed=0
for f in "$PREFIX/ifnh" "$PREFIX/ifnh-uninstall.sh" "$SHARE/man/man1/ifnh.1" \
  "$SHARE/bash-completion/completions/ifnh" "$SHARE/zsh/site-functions/_ifnh" \
  "$SHARE/fish/vendor_completions.d/ifnh.fish"; do
  if [ -f "$f" ]; then rm -f "$f"; echo "  removed $f"; removed=1; fi
done
[ -d "$STATE_DIR" ] && { rm -rf "$STATE_DIR"; echo "  removed $STATE_DIR"; }
if [ "$purge" = 1 ] && [ -d "$CONFIG_DIR" ]; then
  rm -rf "$CONFIG_DIR"
  echo "  removed $CONFIG_DIR (configuration and stored API keys)"
fi
[ "$purge" = 0 ] && [ -d "$CONFIG_DIR" ] && echo "  kept $CONFIG_DIR (config + API keys) - use --purge to delete"
echo "  note: project-local .ifnh/ directories were left untouched."
[ "$removed" = 1 ] && echo "ifnh uninstalled." || echo "ifnh was not found in $PREFIX."
UNINSTALL
install -m 0755 "$tmp/ifnh-uninstall.sh" "$PREFIX/ifnh-uninstall.sh"
echo "ifnh: installed $PREFIX/ifnh-uninstall.sh  (run it to remove ifnh)"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "ifnh: NOTE '$PREFIX' is not on your PATH" >&2
     echo "      add:  export PATH=\"$PREFIX:\$PATH\"  (to ~/.bashrc or ~/.zshrc)" >&2 ;;
esac

"$PREFIX/ifnh" --version
echo "ifnh: next steps — 'cd your/project && ifnh init && ifnh doctor'"
