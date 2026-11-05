#!/bin/sh
# Build the .deb and .rpm for one architecture from the F-01 linux-musl release
# tarball with nfpm (ACTIVE_PLAN F-06). Never builds from source.
#   scripts/package-linux-pkgs.sh <version> <amd64|arm64> [--dist-dir <dir>] [--out <dir>] [--sign-key <armored-private-key>]
# Writes <out>/ifnh_<version>_<arch>.deb and <out>/ifnh-<version>.<x86_64|aarch64>.rpm
# (out defaults to dist-pkgs). The tarball is read from --dist-dir (its .sha256
# is checked) or downloaded, with its .sha256, from
# ${IFNH_RELEASE_BASE_URL:-https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download}/v<version>/.
# Without --sign-key the packages are UNSIGNED and this says so; with it, nfpm
# signs both (passphrase, if any, in NFPM_PASSPHRASE). apt/dnf trust comes from
# the signed repository metadata (scripts/publish-apt-repo.sh), not from these.
# Requires nfpm on PATH (https://nfpm.goreleaser.com).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
ver=""
arch=""
dist=""
out="dist-pkgs"
key=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dist-dir) [ $# -ge 2 ] || { echo "package-linux-pkgs: --dist-dir needs a value" >&2; exit 2; }; dist="$2"; shift ;;
    --out) [ $# -ge 2 ] || { echo "package-linux-pkgs: --out needs a value" >&2; exit 2; }; out="$2"; shift ;;
    --sign-key) [ $# -ge 2 ] || { echo "package-linux-pkgs: --sign-key needs a value" >&2; exit 2; }; key="$2"; shift ;;
    -*) echo "package-linux-pkgs: unknown argument '$1'" >&2; exit 2 ;;
    *) if [ -z "$ver" ]; then ver="${1#v}"; elif [ -z "$arch" ]; then arch="$1"; else echo "package-linux-pkgs: unexpected '$1'" >&2; exit 2; fi ;;
  esac
  shift
done
if [ -z "$ver" ] || [ -z "$arch" ]; then echo "usage: package-linux-pkgs.sh <version> <amd64|arm64> [options]" >&2; exit 2; fi
case "$arch" in
  amd64) plat=linux-x86_64-musl; rpmarch=x86_64 ;;
  arm64) plat=linux-aarch64-musl; rpmarch=aarch64 ;;
  *) echo "package-linux-pkgs: arch must be amd64 or arm64, got '$arch'" >&2; exit 2 ;;
esac
command -v nfpm > /dev/null 2>&1 || { echo "package-linux-pkgs: nfpm not found on PATH" >&2; exit 1; }
if [ -n "$key" ]; then
  [ -f "$key" ] || { echo "package-linux-pkgs: --sign-key $key does not exist" >&2; exit 1; }
  key=$(cd "$(dirname "$key")" && pwd)/$(basename "$key")
  echo "package-linux-pkgs: signing with $key" >&2
else
  echo "package-linux-pkgs: no --sign-key: packages will be UNSIGNED" >&2
fi

name="ifnh-$ver-$plat"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ -z "$dist" ]; then
  base="${IFNH_RELEASE_BASE_URL:-https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/releases/download}/v$ver"
  curl -fsSL -o "$work/$name.tar.gz" "$base/$name.tar.gz"
  curl -fsSL -o "$work/$name.tar.gz.sha256" "$base/$name.tar.gz.sha256"
  dist="$work"
fi
(cd "$dist" && sha256sum -c "$name.tar.gz.sha256" > /dev/null) || { echo "package-linux-pkgs: checksum mismatch for $name.tar.gz" >&2; exit 1; }
tar -xzf "$dist/$name.tar.gz" -C "$work"
[ -x "$work/$name/ifnh" ] || { echo "package-linux-pkgs: $name.tar.gz has no $name/ifnh" >&2; exit 1; }

mkdir -p "$out"
out=$(cd "$out" && pwd)
export VERSION="$ver" ARCH="$arch" NFPM_KEY_FILE="$key"
cd "$work/$name"
if [ -n "$key" ]; then
  # nfpm reads these for a protected key; harmless when NFPM_PASSPHRASE is unset.
  export NFPM_DEB_PASSPHRASE="${NFPM_PASSPHRASE:-}" NFPM_RPM_PASSPHRASE="${NFPM_PASSPHRASE:-}"
fi
nfpm package -f "$root/packaging/nfpm/nfpm.yaml" -p deb -t "$out/ifnh_${ver}_$arch.deb"
nfpm package -f "$root/packaging/nfpm/nfpm.yaml" -p rpm -t "$out/ifnh-$ver.$rpmarch.rpm"
