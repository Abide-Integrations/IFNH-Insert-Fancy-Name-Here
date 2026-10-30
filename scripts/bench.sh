#!/bin/sh
# IFNH performance budgets (DESIGN §7, M0-T40, ACTIVE_PLAN B-09). Every
# budget is a BUDGET_* constant below; the script exits non-zero if any fails.
#   BUDGET_SIZE_BYTES        binary < 5 MiB
#   BUDGET_STARTUP_MS        mean `config validate` < 50 ms (non-interactive)
#   BUDGET_COLD_START_MS     interactive startup.first_paint < 50 ms
#                            (2 warmups, mean of 5; `printf '/quit\n' | ifnh`)
#   BUDGET_TTFT_MS           mean provider.ttft < 250 ms (fake provider)
#   BUDGET_ROUND_OVERHEAD_MS per-round overhead < 50 ms, defined as
#                            (sum turn.total - sum turn.provider_round
#                             - sum turn.tools_round) / number of rounds,
#                            i.e. engine time spent outside the model and tools
#   BUDGET_RSS_KB            peak RSS < 30720 KB (DESIGN §7 idle memory);
#                            skipped when GNU time (/usr/bin/time -v) is absent
# The agent session talks to scripts/fake_provider.py (python3 required).
# Usage: scripts/bench.sh [path-to-binary]
set -e
BUDGET_SIZE_BYTES=5242880
BUDGET_STARTUP_MS=50
BUDGET_COLD_START_MS=50
BUDGET_TTFT_MS=250
BUDGET_ROUND_OVERHEAD_MS=50
BUDGET_RSS_KB=30720

BIN="${1:-./zig-out/bin/ifnh}"
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0

if ! command -v python3 > /dev/null 2>&1; then
  echo "bench: python3 is required (scripts/fake_provider.py)" >&2
  exit 1
fi

tmp=$(mktemp -d)
srv_pid=
cleanup() {
  [ -n "$srv_pid" ] && kill "$srv_pid" 2> /dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# check NAME VALUE BUDGET: print the metric and OK|FAIL (VALUE < BUDGET).
check() {
  echo "$1: $2"
  if awk -v v="$2" -v b="$3" 'BEGIN { exit !(v < b) }'; then
    echo "  budget $3: OK"
  else
    echo "  budget $3: FAIL"
    fail=1
  fi
}

# trace_vals NAME FILE: the millisecond value of every "[trace] NAME <n>ms" line.
trace_vals() {
  awk -v k="$1" '$1 == "[trace]" && $2 == k { sub(/ms$/, "", $3); print $3 }' "$2"
}

# --- binary size ---
size=$(stat -c%s "$BIN" 2> /dev/null || stat -f%z "$BIN")
echo "binary size: $size bytes"
if [ "$size" -lt "$BUDGET_SIZE_BYTES" ]; then echo "  budget $BUDGET_SIZE_BYTES: OK"; else echo "  budget $BUDGET_SIZE_BYTES: FAIL"; fail=1; fi

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
if [ "$mean_ms" -lt "$BUDGET_STARTUP_MS" ]; then echo "  budget $BUDGET_STARTUP_MS: OK"; else echo "  budget $BUDGET_STARTUP_MS: FAIL"; fail=1; fi

# --- interactive cold start ---
i=0
while [ $i -lt 7 ]; do
  printf '/quit\n' | IFNH_TRACE_STARTUP=1 "$BIN" 2>> "$tmp/cold.trace" > /dev/null || true
  i=$((i + 1))
done
cold=$(trace_vals startup.first_paint "$tmp/cold.trace" | tail -n 5 | awk '{ s += $1; n++ } END { if (n) printf "%.2f", s / n }')
[ -n "$cold" ] || { echo "bench: no startup.first_paint in trace" >&2; exit 1; }
check "interactive cold start (ms)" "$cold" "$BUDGET_COLD_START_MS"

# --- agent session against the fake provider ---
python3 "$HERE/fake_provider.py" --port-file "$tmp/port" &
srv_pid=$!
i=0
while [ ! -s "$tmp/port" ]; do
  i=$((i + 1))
  [ $i -le 100 ] || { echo "bench: fake provider did not start" >&2; exit 1; }
  sleep 0.05
done
export IFNH_MODEL__MODEL=bench-model OPENAI_API_KEY=bench
export IFNH_MODEL__BASE_URL="http://$(cat "$tmp/port")"
printf 'one\ntwo\n/quit\n' > "$tmp/input"

IFNH_TRACE_STARTUP=1 "$BIN" < "$tmp/input" 2> "$tmp/session.trace" > /dev/null || true

ttft=$(trace_vals provider.ttft "$tmp/session.trace" | awk '{ s += $1; n++ } END { if (n) printf "%.2f", s / n }')
[ -n "$ttft" ] || { echo "bench: no provider.ttft in trace (session failed?)" >&2; exit 1; }
check "provider ttft mean (ms)" "$ttft" "$BUDGET_TTFT_MS"

overhead=$(awk '
  $1 == "[trace]" { v = $3; sub(/ms$/, "", v) }
  $1 == "[trace]" && $2 == "turn.total" { tot += v }
  $1 == "[trace]" && $2 == "turn.provider_round" { prov += v; rounds++ }
  $1 == "[trace]" && $2 == "turn.tools_round" { tools += v }
  END { if (rounds) printf "%.2f", (tot - prov - tools) / rounds }' "$tmp/session.trace")
[ -n "$overhead" ] || { echo "bench: no turn.provider_round in trace" >&2; exit 1; }
check "per-round overhead (ms)" "$overhead" "$BUDGET_ROUND_OVERHEAD_MS"

if [ -x /usr/bin/time ] && /usr/bin/time -v true > /dev/null 2>&1; then
  /usr/bin/time -v -o "$tmp/time.out" "$BIN" < "$tmp/input" > /dev/null 2>&1 || true
  rss=$(awk -F': ' '/Maximum resident set size/ { print $2 }' "$tmp/time.out")
  [ -n "$rss" ] || { echo "bench: no Maximum resident set size in time output" >&2; exit 1; }
  check "peak RSS (KB)" "$rss" "$BUDGET_RSS_KB"
else
  echo "peak RSS: skipped (GNU time /usr/bin/time -v not available)"
fi

# --- hyperfine comparison when available (T266) ---
if command -v hyperfine > /dev/null 2>&1; then
  echo "--- hyperfine detail ---"
  hyperfine -N -w 3 -m 30 "$BIN config validate" || true
fi

exit $fail
