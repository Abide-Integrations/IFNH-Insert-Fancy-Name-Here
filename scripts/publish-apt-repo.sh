#!/bin/sh
# Build a GPG-signed apt repository (and a signed dnf/rpm repository) from the
# packages made by scripts/package-linux-pkgs.sh (ACTIVE_PLAN F-06). Runs
# locally against a directory; no network and no credentials unless --push.
#   scripts/publish-apt-repo.sh --pkg-dir <dir> --out <dir> --key <fingerprint> [--suite stable] [--push]
# Reads every ifnh_*.deb and ifnh-*.rpm in --pkg-dir and writes the site root <out>:
#   apt/ifnh-archive-keyring.{asc,gpg}   public key (armored / binary for signed-by)
#   apt/pool/main/i/ifnh/*.deb
#   apt/dists/<suite>/{Release,InRelease,Release.gpg}, main/binary-<arch>/Packages{,.gz}
#   rpm/*.rpm, rpm/repodata/ (createrepo_c), rpm/repodata/repomd.xml.asc, rpm/RPM-GPG-KEY-ifnh
# --key names a secret key already in the current GPG keyring (GNUPGHOME);
# GPG_PASSPHRASE, if set, unlocks it. The private key is never written anywhere.
# Needs apt-ftparchive (apt-utils), gpg, gzip. createrepo_c is optional: without
# it (or without rpms) the rpm repo is skipped with a message and rpm/ is not created.
# --push (CI, release events only) replaces apt/ and rpm/ on the gh-pages branch of
# $GITHUB_REPOSITORY, authenticating with $GITHUB_TOKEN as an HTTP header.
# Only the packages in --pkg-dir are published: older releases drop out of the repo.
set -eu

pkgdir=""
out=""
key=""
suite="stable"
push=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pkg-dir) [ $# -ge 2 ] || { echo "publish-apt-repo: --pkg-dir needs a value" >&2; exit 2; }; pkgdir="$2"; shift ;;
    --out) [ $# -ge 2 ] || { echo "publish-apt-repo: --out needs a value" >&2; exit 2; }; out="$2"; shift ;;
    --key) [ $# -ge 2 ] || { echo "publish-apt-repo: --key needs a value" >&2; exit 2; }; key="$2"; shift ;;
    --suite) [ $# -ge 2 ] || { echo "publish-apt-repo: --suite needs a value" >&2; exit 2; }; suite="$2"; shift ;;
    --push) push=1 ;;
    *) echo "publish-apt-repo: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
if [ -z "$pkgdir" ] || [ -z "$out" ] || [ -z "$key" ]; then
  echo "usage: publish-apt-repo.sh --pkg-dir <dir> --out <dir> --key <fingerprint> [--suite stable] [--push]" >&2
  exit 2
fi
for c in apt-ftparchive gpg gzip; do
  command -v "$c" > /dev/null 2>&1 || { echo "publish-apt-repo: $c not found on PATH" >&2; exit 1; }
done
ls "$pkgdir"/ifnh_*.deb > /dev/null 2>&1 || { echo "publish-apt-repo: no ifnh_*.deb in $pkgdir" >&2; exit 1; }
gpg --batch --list-secret-keys "$key" > /dev/null 2>&1 || { echo "publish-apt-repo: no secret key '$key' in the GPG keyring" >&2; exit 1; }

# sign <gpg args...>: non-interactive, passphrase on stdin (empty for an unprotected key).
sign() { printf '%s' "${GPG_PASSPHRASE:-}" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --local-user "$key" "$@"; }

pkgdir=$(cd "$pkgdir" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -rf "$out/apt" "$out/rpm"

# --- apt -----------------------------------------------------------------------
apt="$out/apt"
mkdir -p "$apt/pool/main/i/ifnh"
cp "$pkgdir"/ifnh_*.deb "$apt/pool/main/i/ifnh/"
gpg --batch --export --armor "$key" > "$apt/ifnh-archive-keyring.asc"
gpg --batch --export "$key" > "$apt/ifnh-archive-keyring.gpg"
archs=""
for arch in amd64 arm64; do
  ls "$apt/pool/main/i/ifnh/"ifnh_*_"$arch".deb > /dev/null 2>&1 || continue
  archs="$archs $arch"
  d="$apt/dists/$suite/main/binary-$arch"
  mkdir -p "$d"
  (cd "$apt" && apt-ftparchive --arch "$arch" packages pool > "dists/$suite/main/binary-$arch/Packages")
  gzip -9nk "$d/Packages"
done
archs=${archs# }
# Written outside dists/ first so Release does not list itself.
(cd "$apt" && apt-ftparchive \
  -o "APT::FTPArchive::Release::Origin=IFNH" -o "APT::FTPArchive::Release::Label=IFNH" \
  -o "APT::FTPArchive::Release::Suite=$suite" -o "APT::FTPArchive::Release::Codename=$suite" \
  -o "APT::FTPArchive::Release::Architectures=$archs" -o "APT::FTPArchive::Release::Components=main" \
  release "dists/$suite" > ../Release.tmp)
mv "$out/Release.tmp" "$apt/dists/$suite/Release"
sign --clearsign -o "$apt/dists/$suite/InRelease" "$apt/dists/$suite/Release"
sign --armor --detach-sign -o "$apt/dists/$suite/Release.gpg" "$apt/dists/$suite/Release"
echo "publish-apt-repo: apt repo ($suite; $archs) written to $apt" >&2

# --- rpm -----------------------------------------------------------------------
if ! ls "$pkgdir"/ifnh-*.rpm > /dev/null 2>&1; then
  echo "publish-apt-repo: SKIP rpm repo: no ifnh-*.rpm in $pkgdir" >&2
elif ! command -v createrepo_c > /dev/null 2>&1; then
  echo "publish-apt-repo: SKIP rpm repo: createrepo_c not found on PATH (nothing written under rpm/)" >&2
else
  rpmd="$out/rpm"
  mkdir -p "$rpmd"
  cp "$pkgdir"/ifnh-*.rpm "$rpmd/"
  gpg --batch --export --armor "$key" > "$rpmd/RPM-GPG-KEY-ifnh"
  createrepo_c --quiet "$rpmd"
  sign --armor --detach-sign -o "$rpmd/repodata/repomd.xml.asc" "$rpmd/repodata/repomd.xml"
  echo "publish-apt-repo: rpm repo written to $rpmd" >&2
fi

[ "$push" = 1 ] || exit 0
: "${GITHUB_REPOSITORY:?publish-apt-repo: --push needs GITHUB_REPOSITORY}"
: "${GITHUB_TOKEN:?publish-apt-repo: --push needs GITHUB_TOKEN}"
auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
site=$(mktemp -d)
trap 'rm -rf "$site"' EXIT
git init -q -b gh-pages "$site"
git -C "$site" remote add origin "https://github.com/$GITHUB_REPOSITORY.git"
# A missing gh-pages branch is fine: the first publish creates it.
if git -C "$site" -c http.extraheader="$auth" fetch -q --depth 1 origin gh-pages; then
  git -C "$site" reset -q --hard FETCH_HEAD
fi
rm -rf "$site/apt" "$site/rpm"
cp -R "$out/apt" "$site/apt"
[ ! -d "$out/rpm" ] || cp -R "$out/rpm" "$site/rpm"
touch "$site/.nojekyll"
git -C "$site" add -A
git -C "$site" diff --cached --quiet && { echo "publish-apt-repo: gh-pages already up to date" >&2; exit 0; }
git -C "$site" -c user.name="ifnh-release" -c user.email="noreply@users.noreply.github.com" commit -q -m "apt/rpm repo update"
git -C "$site" -c http.extraheader="$auth" push origin gh-pages
