#!/bin/sh
# Build, stage and package ONE release target (ACTIVE_PLAN F-01). Shared by
# .github/workflows/release.yml and scripts/release-dry-run.sh so the CI run
# and the local rehearsal cannot drift.
#   scripts/package-release.sh <zig-target> <out-dir>
# Writes to <out-dir>:
#   ifnh-<version>-<os>-<arch>[-<abi>].tar.gz          ifnh, share/man, share/*completions
#   ifnh-<version>-<os>-<arch>[-<abi>].tar.gz.sha256   sha256sum format
#   ifnh-<version>-<os>-<arch>[-<abi>].spdx.json       syft SBOM of the staged binary
# and prints the base name (no extension) on stdout. Signing is separate.
# Env:
#   IFNH_COMMIT    commit id baked into `version --verbose` (default: git short sha)
#   IFNH_HOST_BIN  host-native ifnh used to generate completions; a cross-compiled
#                  binary cannot run on the build host, and the scripts do not
#                  depend on the target. Default: built here, native, ReleaseSafe.
set -eu

target="${1:?usage: package-release.sh <zig-target> <out-dir>}"
out="${2:?usage: package-release.sh <zig-target> <out-dir>}"
root=$(cd "$(dirname "$0")/.." && pwd)

case "$target" in
  x86_64-linux-musl)  plat=linux-x86_64-musl ;;
  x86_64-linux-gnu)   plat=linux-x86_64-gnu ;;
  aarch64-linux-musl) plat=linux-aarch64-musl ;;
  aarch64-macos)      plat=macos-aarch64 ;;
  x86_64-macos)       plat=macos-x86_64 ;;
  *) echo "package-release: unsupported target '$target'" >&2; exit 2 ;;
esac
command -v syft > /dev/null 2>&1 || { echo "package-release: syft not found on PATH" >&2; exit 1; }

version=$("$root/scripts/check-version.sh" --print)
name="ifnh-$version-$plat"
commit="${IFNH_COMMIT:-$(git -C "$root" rev-parse --short HEAD 2> /dev/null || echo unknown)}"
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$root"
echo "package-release: building $target ($name, commit $commit)" >&2
zig build -Doptimize=ReleaseSafe -Dtarget="$target" -Dcommit="$commit" -p "$work/prefix" >&2

host_bin="${IFNH_HOST_BIN:-}"
if [ -z "$host_bin" ]; then
  zig build -Doptimize=ReleaseSafe -Dcommit="$commit" -p "$work/host" >&2
  host_bin="$work/host/bin/ifnh"
fi

stage="$work/stage/$name"
mkdir -p "$stage/share/man/man1" "$stage/share/bash-completion/completions" \
  "$stage/share/zsh/site-functions" "$stage/share/fish/vendor_completions.d"
install -m 0755 "$work/prefix/bin/ifnh" "$stage/ifnh"
install -m 0644 man/ifnh.1 "$stage/share/man/man1/ifnh.1"
"$host_bin" completions bash > "$stage/share/bash-completion/completions/ifnh"
"$host_bin" completions zsh > "$stage/share/zsh/site-functions/_ifnh"
"$host_bin" completions fish > "$stage/share/fish/vendor_completions.d/ifnh.fish"
chmod 0644 "$stage"/share/*/*/*

tar --owner=0 --group=0 --numeric-owner -czf "$out/$name.tar.gz" -C "$work/stage" "$name"
(cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
syft scan "file:$stage/ifnh" -o "spdx-json=$out/$name.spdx.json" >&2

echo "$name"
