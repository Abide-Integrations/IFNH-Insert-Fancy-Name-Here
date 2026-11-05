#!/bin/sh
# Local rehearsal of .github/workflows/release.yml (ACTIVE_PLAN F-01): builds,
# stages and packages every release target with the same script CI uses, then
# checks names, layout and checksums. Never publishes anything.
#   scripts/release-dry-run.sh [--target <zig-target>]... [--out <dir>] [--sign-key <cosign.key>]
# Defaults: all five targets, out dir zig-out/release-dry-run.
# Signing: the real release signs keyless (Sigstore + GitHub OIDC), which only
# exists inside GitHub Actions, so it is reported SKIP here. With --sign-key a
# local cosign key signs each tarball offline (no transparency log) and the
# bundle is verified with the matching public key (cosign v3; COSIGN_PASSWORD if needed).
# Requires zig 0.16.0, syft, GNU tar, sha256sum. Exits non-zero if any
# non-skipped step fails.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/zig-out/release-dry-run"
sign_key=""
targets=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   [ $# -ge 2 ] || { echo "release-dry-run: --target needs a value" >&2; exit 2; }; targets="$targets $2"; shift ;;
    --out)      [ $# -ge 2 ] || { echo "release-dry-run: --out needs a value" >&2; exit 2; }; out="$2"; shift ;;
    --sign-key) [ $# -ge 2 ] || { echo "release-dry-run: --sign-key needs a value" >&2; exit 2; }; sign_key="$2"; shift ;;
    *) echo "release-dry-run: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$targets" ] || targets="x86_64-linux-musl x86_64-linux-gnu aarch64-linux-musl aarch64-macos x86_64-macos"

fail() { echo "FAIL $*" >&2; exit 1; }

"$root/scripts/check-version.sh" || fail "version consistency"
version=$("$root/scripts/check-version.sh" --print)

rm -rf "$out"
mkdir -p "$out"
commit=$(git -C "$root" rev-parse --short HEAD 2> /dev/null || echo unknown)
host=$(mktemp -d)
trap 'rm -rf "$host"' EXIT
(cd "$root" && zig build -Doptimize=ReleaseSafe -Dcommit="$commit" -p "$host") || fail "host build"
export IFNH_HOST_BIN="$host/bin/ifnh" IFNH_COMMIT="$commit"

names=""
for t in $targets; do
  name=$("$root/scripts/package-release.sh" "$t" "$out") || fail "package $t"
  names="$names $name"

  tar -tzf "$out/$name.tar.gz" > "$host/list" || fail "$name: unreadable tarball"
  for f in ifnh share/man/man1/ifnh.1 share/bash-completion/completions/ifnh \
    share/zsh/site-functions/_ifnh share/fish/vendor_completions.d/ifnh.fish; do
    grep -qx "$name/$f" "$host/list" || fail "$name: tarball is missing $f"
  done
  (cd "$out" && sha256sum -c "$name.tar.gz.sha256" > /dev/null) || fail "$name: sha256 mismatch"
  grep -q '"spdxVersion"' "$out/$name.spdx.json" || fail "$name: SBOM is not SPDX JSON"

  if [ -n "$sign_key" ]; then
    command -v cosign > /dev/null 2>&1 || fail "cosign not found (needed for --sign-key)"
    cosign sign-blob --yes --key "$sign_key" --use-signing-config=false --tlog-upload=false \
      --bundle "$out/$name.tar.gz.cosign.bundle" "$out/$name.tar.gz" > /dev/null || fail "$name: cosign sign"
    cosign public-key --key "$sign_key" > "$host/cosign.pub" || fail "cosign public-key"
    cosign verify-blob --key "$host/cosign.pub" --insecure-ignore-tlog=true \
      --bundle "$out/$name.tar.gz.cosign.bundle" "$out/$name.tar.gz" > /dev/null 2>&1 || fail "$name: cosign verify"
    echo "OK   cosign key-signed and verified $name.tar.gz"
  fi
done
[ -n "$sign_key" ] || echo "SKIP cosign keyless needs GitHub OIDC"

echo "release dry run: version $version, commit $commit, out $out"
(cd "$out" && ls -1 && sha256sum ./*.tar.gz)
echo "release dry run: OK (nothing was published)"
