#!/bin/bash
# Unit tests for src/statusline/refresh-metrics.sh. Runs for real on whatever
# platform the suite executes on (macOS vm_stat vs Linux /proc/meminfo) -
# there's no meaningful way to fake system memory, so this just checks the
# output shape and internal consistency.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

REFRESH="$REPO_ROOT/src/statusline/refresh-metrics.sh"
SEP=$'\034'

section "real system metrics"
th_run bash "$REFRESH"
assert_status "exits 0" 0 "$TH_STATUS"

IFS="$SEP" read -r used total pct <<< "$TH_OUT"
assert_match "used is a decimal number of GiB" "$used" '^[0-9]+\.[0-9]$'
assert_match "total is a decimal number of GiB" "$total" '^[0-9]+\.[0-9]$'
assert_match "percent is an integer" "$pct" '^[0-9]+$'

used_int="${used%%.*}"
total_int="${total%%.*}"
[ "$used_int" -le "$total_int" ]
assert_status "used does not exceed total" 0 $?

[ "$pct" -ge 0 ] && [ "$pct" -le 100 ]
assert_status "percent is within 0-100" 0 $?

section "resource-guard's last line, when at most 3 min old"
FAKE="$(mktemp -d)"; mkdir -p "$FAKE/opt/resource-guard/data"
RG="$FAKE/opt/resource-guard/data/$(date -u +%Y-%m).tsv"
printf 'ts\tdt\tcpu_pct\tcpu_max_pct\ttotal_gb\tused_gb\n%s\tx\t1\t2\t16.0\t12.04\n' "$(date +%s)" > "$RG"
th_run env HOME="$FAKE" bash "$REFRESH"
assert_eq "used, total, percent come from the line" "12.0${SEP}16.0${SEP}75" "$TH_OUT"
printf 'ts\tdt\tcpu_pct\tcpu_max_pct\ttotal_gb\tused_gb\n%s\tx\t1\t2\t16.0\t12.04\n' "$(( $(date +%s) - 600 ))" > "$RG"
th_run env HOME="$FAKE" bash "$REFRESH"
assert_status "a 10-min-old line: computed instead, exits 0" 0 "$TH_STATUS"
[ "$TH_OUT" != "12.0${SEP}16.0${SEP}75" ]
assert_status "  ...and not the stale value" 0 $?
rm -rf "$FAKE"

harness_summary
