#!/bin/sh
# Offline smoke test for install.sh (ACTIVE_PLAN F-01/F-09). A fake curl serves
# a fake release tarball; nothing touches the network or the real HOME.
#   tests/smoke-install.sh
# Checks: clean install (binary, uninstaller, man page, completions, latest-tag
# lookup); package-managed refusal (Homebrew path, apt probe, IFNH_PREFIX does
# not bypass); checksum mismatch aborts; user config and project .ifnh/ are
# byte-identical before and after every scenario, uninstaller included.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

case "$(uname -s)" in Linux) tos=linux ;; Darwin) tos=macos ;; *) echo "SKIP unsupported OS"; exit 0 ;; esac
case "$(uname -m)" in x86_64|amd64) tarch=x86_64 ;; aarch64|arm64) tarch=aarch64 ;; *) echo "SKIP unsupported arch"; exit 0 ;; esac
if [ "$tos" = linux ]; then plat="linux-$tarch-musl"; else plat="macos-$tarch"; fi
name="ifnh-9.9.9-$plat"

# --- fake release: <name>.tar.gz + .sha256 -----------------------------------
rel="$T/release"
stage="$T/stage/$name"
mkdir -p "$rel" "$stage/share/man/man1" "$stage/share/bash-completion/completions" \
  "$stage/share/zsh/site-functions" "$stage/share/fish/vendor_completions.d"
printf '#!/bin/sh\necho "ifnh 9.9.9"\n' > "$stage/ifnh"
chmod 0755 "$stage/ifnh"
echo ".TH IFNH 1" > "$stage/share/man/man1/ifnh.1"
echo "# bash" > "$stage/share/bash-completion/completions/ifnh"
echo "#compdef ifnh" > "$stage/share/zsh/site-functions/_ifnh"
echo "# fish" > "$stage/share/fish/vendor_completions.d/ifnh.fish"
tar -czf "$rel/$name.tar.gz" -C "$T/stage" "$name"
if command -v sha256sum > /dev/null 2>&1; then
  (cd "$rel" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
else
  (cd "$rel" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
fi
cp "$rel/$name.tar.gz.sha256" "$T/good.sha256"

# --- fake curl: serves $rel, the latest-release API, logs every URL ----------
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'CURL'
#!/bin/sh
url=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; http*) url="$1" ;; esac
  shift
done
echo "$url" >> "$FAKE_LOG"
case "$url" in
  */releases/latest)
    [ -z "${FAKE_NO_API:-}" ] || exit 22
    printf '{\n  "url": "x",\n  "tag_name": "v9.9.9",\n  "name": "v9.9.9"\n}\n' > "$out" ;;
  */releases/download/v9.9.9/*) f="$FAKE_RELEASE/${url##*/}"; [ -f "$f" ] || exit 22; cp "$f" "$out" ;;
  *) echo "fake curl: unexpected URL $url" >&2; exit 22 ;;
esac
CURL
chmod +x "$T/bin/curl"
export FAKE_RELEASE="$rel" FAKE_LOG="$T/curl.log"

# --- scenario plumbing -------------------------------------------------------
snapshot() { (cd "$1" && find . -type f -exec cksum {} + | sort); }

# new_home: fresh HOME with user config and a project .ifnh/ that must survive.
new_home() {
  H="$T/home.$1"
  rm -rf "$H"
  mkdir -p "$H/.config/ifnh" "$H/proj/.ifnh"
  echo '{"model":{"model":"keep-me"}}' > "$H/.config/ifnh/config.json"
  echo 'KEY=secret-do-not-touch' > "$H/.config/ifnh/env"
  echo '{"project":true}' > "$H/proj/.ifnh/config.json"
  snapshot "$H/.config" > "$T/cfg.before"
  snapshot "$H/proj" > "$T/proj.before"
  : > "$FAKE_LOG"
}
user_data_untouched() {
  snapshot "$H/.config" | cmp -s - "$T/cfg.before" || fail "$1: ~/.config/ifnh changed"
  snapshot "$H/proj" | cmp -s - "$T/proj.before" || fail "$1: project .ifnh/ changed"
}
# run_install <extra PATH dir or ""> [env assignments...]: sets rc, $T/out, $T/err
run_install() {
  extra="$1"; shift
  rc=0
  (cd "$H/proj" && env HOME="$H" IFNH_PREFIX="$H/.local/bin" IFNH_VERSION=v9.9.9 \
    PATH="${extra:+$extra:}$T/bin:/usr/bin:/bin" "$@" sh "$root/install.sh") > "$T/out" 2> "$T/err" || rc=$?
}

# --- (a) clean install -------------------------------------------------------
new_home a
run_install ""
[ "$rc" = 0 ] || { cat "$T/err"; fail "(a) clean install exited $rc"; }
for f in .local/bin/ifnh .local/bin/ifnh-uninstall.sh .local/share/man/man1/ifnh.1 \
  .local/share/bash-completion/completions/ifnh .local/share/zsh/site-functions/_ifnh \
  .local/share/fish/vendor_completions.d/ifnh.fish; do
  [ -f "$H/$f" ] || fail "(a) missing $f"
done
[ "$("$H/.local/bin/ifnh")" = "ifnh 9.9.9" ] || fail "(a) installed binary is not the release binary"
user_data_untouched "(a)"
ok "(a) clean install: binary, uninstaller, man page, completions"

# latest-release lookup (no IFNH_VERSION)
new_home a2
run_install "" IFNH_VERSION=
[ "$rc" = 0 ] || { cat "$T/err"; fail "(a2) latest lookup exited $rc"; }
grep -q 'api.github.com/repos/.*/releases/latest' "$FAKE_LOG" || fail "(a2) did not query the latest release"
grep -q "releases/download/v9.9.9/$name.tar.gz\$" "$FAKE_LOG" || fail "(a2) did not download the resolved tag"
ok "(a2) latest tag resolved from the releases API"

new_home a3
run_install "" IFNH_VERSION= FAKE_NO_API=1
[ "$rc" != 0 ] || fail "(a3) unresolved latest tag must fail"
grep -q 'set IFNH_VERSION' "$T/err" || fail "(a3) error does not mention IFNH_VERSION"
[ ! -e "$H/.local" ] || fail "(a3) wrote to the prefix"
ok "(a3) unresolvable latest tag: one-line error naming IFNH_VERSION"

# uninstaller keeps config and .ifnh/
(cd "$H/proj" && env HOME="$H" IFNH_PREFIX="$H/.local/bin" sh "$root/uninstall.sh" > /dev/null) || fail "uninstall.sh failed"
[ ! -e "$H/.local/bin/ifnh" ] || fail "uninstall.sh left the binary"
new_home a4
run_install ""
(cd "$H/proj" && env HOME="$H" IFNH_PREFIX="$H/.local/bin" "$H/.local/bin/ifnh-uninstall.sh" > /dev/null) || fail "ifnh-uninstall.sh failed"
[ ! -e "$H/.local/bin/ifnh" ] && [ ! -e "$H/.local/share/man/man1/ifnh.1" ] || fail "ifnh-uninstall.sh left files behind"
user_data_untouched "(a4)"
ok "(a4) generated uninstaller removes files, keeps ~/.config/ifnh and .ifnh/"

# --- (b) package-managed installs are refused --------------------------------
new_home b1
mkdir -p "$T/brew/Cellar/ifnh/1.0/bin"
printf '#!/bin/sh\necho brew-ifnh\n' > "$T/brew/Cellar/ifnh/1.0/bin/ifnh"
chmod +x "$T/brew/Cellar/ifnh/1.0/bin/ifnh"
run_install "$T/brew/Cellar/ifnh/1.0/bin"
[ "$rc" = 1 ] || fail "(b1) expected exit 1, got $rc"
grep -q '^ifnh: refusing to overwrite a package-managed install (Homebrew); upgrade with brew upgrade ifnh$' "$T/err" || { cat "$T/err"; fail "(b1) wrong message"; }
[ ! -s "$FAKE_LOG" ] || fail "(b1) downloaded something before refusing"
[ ! -e "$H/.local" ] || fail "(b1) prefix touched"
user_data_untouched "(b1)"
ok "(b1) Homebrew path refused, nothing downloaded or written"

new_home b2
run_install "$T/brew/Cellar/ifnh/1.0/bin" IFNH_PREFIX="$T/other-prefix"
[ "$rc" = 1 ] && [ ! -e "$T/other-prefix" ] || fail "(b2) IFNH_PREFIX bypassed the check"
ok "(b2) IFNH_PREFIX does not bypass"

new_home b3
mkdir -p "$T/apt"
printf '#!/bin/sh\necho apt-ifnh\n' > "$T/apt/ifnh"
printf '#!/bin/sh\nexit 0\n' > "$T/apt/dpkg-query"
chmod +x "$T/apt/ifnh" "$T/apt/dpkg-query"
run_install "$T/apt"
[ "$rc" = 1 ] || fail "(b3) expected exit 1, got $rc"
grep -q 'package-managed install (apt); upgrade with ' "$T/err" || { cat "$T/err"; fail "(b3) wrong message"; }
[ ! -e "$H/.local" ] || fail "(b3) prefix touched"
user_data_untouched "(b3)"
ok "(b3) dpkg-query ownership refused"

# an ifnh from a previous install.sh run (not package-owned) may be upgraded
new_home b4
run_install ""
run_install "$H/.local/bin"
[ "$rc" = 0 ] || { cat "$T/err"; fail "(b4) upgrading a script-installed ifnh exited $rc"; }
ok "(b4) a script-installed ifnh upgrades in place"

# --- (c) checksum mismatch aborts --------------------------------------------
new_home c
echo "0000000000000000000000000000000000000000000000000000000000000000  $name.tar.gz" > "$rel/$name.tar.gz.sha256"
run_install ""
[ "$rc" != 0 ] || fail "(c) checksum mismatch must fail"
grep -q 'checksum mismatch' "$T/err" || fail "(c) no mismatch message"
[ ! -e "$H/.local/bin/ifnh" ] || fail "(c) installed despite mismatch"
user_data_untouched "(c)"
ok "(c) sha256 mismatch aborts, nothing installed"

# a missing .sha256 also fails closed
new_home c2
rm -f "$rel/$name.tar.gz.sha256"
run_install ""
[ "$rc" != 0 ] && [ ! -e "$H/.local/bin/ifnh" ] || fail "(c2) missing checksum must fail closed"
cp "$T/good.sha256" "$rel/$name.tar.gz.sha256"
ok "(c2) missing checksum fails closed"

echo "smoke-install: all scenarios passed"
