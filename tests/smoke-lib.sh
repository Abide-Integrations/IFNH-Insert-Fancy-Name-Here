#!/bin/sh
# E-06b smoke: build libifnh.a, compile a small C program against it with
# `zig cc`, run it. Run from anywhere; needs zig on PATH.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
zig build
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
zig cc -o "$work/lib_smoke" tests/lib_smoke.c -Izig-out/include zig-out/lib/libifnh.a
out=$("$work/lib_smoke" "$work")
echo "$out"
want=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' src/version.zig)
[ "$out" = "libifnh $want" ] || { echo "FAIL: expected 'libifnh $want'"; exit 1; }
echo "lib smoke: OK"
