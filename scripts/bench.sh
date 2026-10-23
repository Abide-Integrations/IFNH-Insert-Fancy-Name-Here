#!/bin/sh
# IFNH performance budgets (DESIGN §7, M0-T40, ACTIVE_PLAN B-09):
#   subcommand startup < 50ms mean
#   interactive cold start < 100ms mean
#   peak RSS < 32 MiB on interactive cold start
#   binary < 5 MiB stripped
#
# Optional round benchmark (needs a configured provider/model):
#   IFNH_BENCH_PROMPT='say hi' scripts/bench.sh
# prints the B-01 per-round spans, including provider.ttft (time to first token).
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

# --- interactive cold start (20 runs, piped /quit) ---
total=0
runs=20
i=0
while [ $i -lt $runs ]; do
  start=$(date +%s%N)
  printf '/quit\n' | "$BIN" > /dev/null 2>&1 || true
  end=$(date +%s%N)
  total=$((total + (end - start)))
  i=$((i + 1))
done
mean_ms=$((total / runs / 1000000))
echo "interactive cold start mean: ${mean_ms}ms over $runs runs"
if [ "$mean_ms" -lt 100 ]; then echo "  budget 100ms: OK"; else echo "  budget 100ms: FAIL"; fail=1; fi

# --- peak RSS on the interactive path ---
if command -v /usr/bin/time > /dev/null 2>&1 && /usr/bin/time -v true > /dev/null 2>&1; then
  rss=$( { /usr/bin/time -v sh -c "printf '/quit\\n' | '$BIN' > /dev/null" > /dev/null; } 2>&1 | sed -n 's/.*Maximum resident set size (kbytes): //p')
  echo "interactive peak RSS: ${rss} KiB"
  if [ -n "$rss" ] && [ "$rss" -lt 32768 ]; then echo "  budget 32768 KiB: OK"; else echo "  budget 32768 KiB: FAIL"; fail=1; fi
fi

# --- optional per-round overhead + TTFT trace ---
if [ -n "${IFNH_BENCH_PROMPT:-}" ]; then
  echo "--- round trace (IFNH_BENCH_PROMPT) ---"
  printf '%s\n/quit\n' "$IFNH_BENCH_PROMPT" | IFNH_TRACE_STARTUP=1 "$BIN" 2>&1 > /dev/null | grep -E 'turn\.|provider\.ttft|first_paint' || true
fi

# --- hyperfine comparison when available (T266) ---
if command -v hyperfine > /dev/null 2>&1; then
  echo "--- hyperfine detail ---"
  hyperfine -N -w 3 -m 30 "$BIN config validate" || true
fi

exit $fail
