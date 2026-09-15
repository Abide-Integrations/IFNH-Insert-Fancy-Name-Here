#!/bin/sh
# IFNH performance budgets (DESIGN §7, M0-T40):
#   startup < 50ms mean interactive-equivalent subcommand
#   binary < 5 MiB stripped
# Usage: scripts/bench.sh [path-to-binary]
set -e
BIN="${1:-./zig-out/bin/ifnh}"
fail=0

# --- binary size ---
size=$(stat -c%s "$BIN" 2>/dev/null || stat -f%z "$BIN")
echo "binary size: $size bytes"
if [ "$size" -lt 5242880 ]; then echo "  budget 5242880: OK"; else echo "  budget 5242880: FAIL"; fail=1; fi

# --- startup timing (20 runs of a non-interactive subcommand) ---
total=0
runs=20
i=0
while [ $i -lt $runs ]; do
  start=$(date +%s%N)
  "$BIN" config validate > /dev/null 2>&1 || "$BIN" --version > /dev/null
  end=$(date +%s%N)
  total=$((total + (end - start)))
  i=$((i + 1))
done
mean_ms=$((total / runs / 1000000))
echo "startup mean: ${mean_ms}ms over $runs runs"
if [ "$mean_ms" -lt 50 ]; then echo "  budget 50ms: OK"; else echo "  budget 50ms: FAIL"; fail=1; fi

# --- hyperfine comparison when available (T266) ---
if command -v hyperfine > /dev/null 2>&1; then
  echo "--- hyperfine detail ---"
  hyperfine -N -w 3 -m 30 "$BIN config validate" || true
fi

exit $fail
