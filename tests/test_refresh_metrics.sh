#!/bin/bash
# Unit tests for lib/statusline-refresh-metrics.sh. Runs for real on whatever
# platform the suite executes on (macOS vm_stat vs Linux /proc/meminfo) -
# there's no meaningful way to fake system memory, so this just checks the
# output shape and internal consistency.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

REFRESH="$REPO_ROOT/lib/statusline-refresh-metrics.sh"
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

harness_summary
