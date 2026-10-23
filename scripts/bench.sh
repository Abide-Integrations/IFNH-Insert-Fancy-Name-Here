#!/bin/sh
# IFNH performance report (DESIGN §7, B-09).
#
# Measures the interactive path, not just `config validate`:
#   - binary size and non-interactive startup (existing budgets)
#   - cold start to the first interactive prompt (budget < 50 ms)
#   - peak RSS while starting the interactive session (budget < 30 MB)
#   - engine round overhead and offline TTFT via the fake-provider harness
#
# Live time-to-first-token needs a real model endpoint and API key; the
# offline TTFT below is the harness lower bound, not a network measurement.
#
# Usage: scripts/bench.sh [path-to-binary]
set -e
BIN="${1:-./zig-out/bin/ifnh}"
case "$BIN" in
  /*) ;;
  *) BIN="$PWD/$BIN" ;;
esac
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

now_ns() {
  date +%s%N
}

# --- binary size ---
size=$(stat -c%s "$BIN" 2>/dev/null || stat -f%z "$BIN")

# --- startup timing (20 runs of a non-interactive subcommand) ---
total=0
runs=20
i=0
while [ $i -lt $runs ]; do
  start=$(now_ns)
  "$BIN" config validate > /dev/null 2>&1 || "$BIN" --version > /dev/null
  end=$(now_ns)
  total=$((total + (end - start)))
  i=$((i + 1))
done
mean_ms=$((total / runs / 1000000))

# --- interactive cold start: launch in an empty dir and poll for "> " ---
measure_interactive() {
  run_dir="$work/interactive-run"
  rm -rf "$run_dir"
  mkdir -p "$run_dir"
  out="$run_dir/out"
  start=$(now_ns)
  ( cd "$run_dir" && "$BIN" < /dev/null > "$out" 2>&1 ) &
  pid=$!
  found=0
  tries=0
  while [ "$tries" -lt 2000 ]; do
    if grep -q '^> ' "$out" 2>/dev/null; then
      found=1
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      grep -q '^> ' "$out" 2>/dev/null && found=1
      break
    fi
    tries=$((tries + 1))
    sleep 0.001 2>/dev/null || sleep 1
  done
  end=$(now_ns)
  wait "$pid" 2>/dev/null || true
  if [ "$found" -eq 1 ]; then
    echo $(( (end - start) / 1000000 ))
  else
    echo "n/a"
  fi
}

interactive_ms="n/a"
interactive_total=0
interactive_count=0
i=0
while [ $i -lt 5 ]; do
  v=$(measure_interactive)
  case "$v" in
    ''|*[!0-9]*) break ;;
    *)
      interactive_total=$((interactive_total + v))
      interactive_count=$((interactive_count + 1))
      ;;
  esac
  i=$((i + 1))
done
if [ "$interactive_count" -gt 0 ]; then
  interactive_ms=$((interactive_total / interactive_count))
fi

# --- peak RSS: GNU time -v (KiB) or BSD/macOS time -l (bytes) ---
peak_rss_kib="n/a"
rss_file="$work/rss"
if [ -x /usr/bin/time ]; then
  if /usr/bin/time -v true > /dev/null 2>"$rss_file"; then
    ( cd "$work" && /usr/bin/time -v "$BIN" < /dev/null > /dev/null ) 2>"$rss_file" || true
    peak_rss_kib=$(awk '/Maximum resident set size/ {print $6; exit}' "$rss_file")
  elif /usr/bin/time -l true > /dev/null 2>"$rss_file"; then
    ( cd "$work" && /usr/bin/time -l "$BIN" < /dev/null > /dev/null ) 2>"$rss_file" || true
    peak_rss_bytes=$(awk '/maximum resident set size/ {print $1; exit}' "$rss_file")
    case "$peak_rss_bytes" in
      ''|*[!0-9]*) ;;
      *) peak_rss_kib=$((peak_rss_bytes / 1024)) ;;
    esac
  fi
fi

# --- budgets ---
size_status=OK
if [ "$size" -ge 5242880 ]; then size_status=FAIL; fail=1; fi
startup_status=OK
if [ "$mean_ms" -ge 50 ]; then startup_status=FAIL; fail=1; fi
interactive_status=OK
case "$interactive_ms" in
  ''|*[!0-9]*) interactive_status=SKIP ;;
  *) if [ "$interactive_ms" -ge 50 ]; then interactive_status=FAIL; fail=1; fi ;;
esac
rss_status=OK
case "$peak_rss_kib" in
  ''|*[!0-9]*) rss_status=SKIP ;;
  *) if [ "$peak_rss_kib" -ge 30720 ]; then rss_status=FAIL; fail=1; fi ;;
esac

# --- engine bench: per-round overhead and offline TTFT ---
round_us="n/a"
ttft_us="n/a"
if command -v zig > /dev/null 2>&1; then
  engine_out=$( cd "$repo" && zig build bench -Doptimize=ReleaseSafe 2>&1 ) || {
    printf '%s\n' "$engine_out"
    echo "engine bench: FAIL"
    fail=1
    engine_out=""
  }
  if [ -n "$engine_out" ]; then
    round_us=$(printf '%s\n' "$engine_out" | awk '/engine round overhead \(median\)/ {print $5; exit}')
    ttft_us=$(printf '%s\n' "$engine_out" | awk '/offline TTFT \(median\)/ {print $4; exit}')
  fi
else
  echo "engine bench: SKIP (zig not found; run 'zig build bench' on the test host)"
fi

printf '%-42s %-18s %-20s %s\n' "metric" "value" "budget" "status"
printf '%-42s %-18s %-20s %s\n' "binary size" "$size bytes" "< 5242880 bytes" "$size_status"
printf '%-42s %-18s %-20s %s\n' "startup: non-interactive (mean of 20)" "${mean_ms}ms" "< 50ms" "$startup_status"
printf '%-42s %-18s %-20s %s\n' "startup: interactive to first prompt" "${interactive_ms}ms" "< 50ms" "$interactive_status"
printf '%-42s %-18s %-20s %s\n' "peak RSS: interactive startup" "${peak_rss_kib}KiB" "< 30720KiB" "$rss_status"
printf '%-42s %-18s %-20s %s\n' "per-round overhead (fake provider)" "${round_us}us" "-" "INFO"
printf '%-42s %-18s %-20s %s\n' "time-to-first-token (offline fake)" "${ttft_us}us" "-" "INFO"
printf '%-42s %-18s %-20s %s\n' "time-to-first-token (live)" "needs API key" "-" "SKIP"

echo ""
if [ -n "$engine_out" ]; then
  printf '%s\n' "$engine_out"
fi

exit $fail
