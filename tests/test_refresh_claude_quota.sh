#!/bin/bash
# End-to-end tests for lib/statusline-refresh-claude-quota.sh. Unlike the old
# statusline-usage-fetch.sh this replaced, there's no Keychain or network to
# stub - the script just reads the latest "claude" row out of a fixture
# quota log, so these tests write that fixture directly. See the script's
# own header comment for why quota/poll_claude.py's log is the source now
# instead of a live API call.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

REFRESH="$REPO_ROOT/lib/statusline-refresh-claude-quota.sh"
SEP=$'\034'

TH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-quotahome.XXXXXX")"
trap 'rm -rf "$TH_HOME"' EXIT
LOG="$TH_HOME/opt/agent-statusline/data/utilization-log.jsonl"

epoch_of() {
    python3 -c "
import calendar, time, sys
print(calendar.timegm(time.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ')))
" "$1"
}

write_log() {
    mkdir -p "$(dirname "$LOG")"
    printf '%s\n' "$1" > "$LOG"
}

run_refresh() {
    local err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    TH_OUT="$(HOME="$TH_HOME" bash "$REFRESH" 2>"$err_file")"
    TH_STATUS=$?
    TH_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}

five_epoch="$(epoch_of '2026-01-01T00:00:00Z')"
seven_epoch="$(epoch_of '2026-01-05T12:30:00Z')"

section "no quota log file at all"
rm -f "$LOG"
run_refresh
assert_status "exits 1" 1 "$TH_STATUS"
assert_contains "explains the log is missing" "$TH_ERR" "quota log not found"

section "log file exists but is empty"
write_log ""
run_refresh
assert_status "exits 1" 1 "$TH_STATUS"
assert_contains "explains no reading was found" "$TH_ERR" "no successful Claude reading found"

section "log has only Codex rows"
write_log '{"ts":1,"source":"codex","codex_rate_limits":{}}'
run_refresh
assert_status "exits 1" 1 "$TH_STATUS"

section "log has only failed Claude reads (api: null)"
write_log '{"ts":1,"source":"claude","api":null,"error":{"stage":"http"}}'
run_refresh
assert_status "exits 1" 1 "$TH_STATUS"

section "successful read, amid Codex and failed rows"
write_log "$(cat <<EOF
{"ts":1,"source":"codex","codex_rate_limits":{}}
{"ts":2,"source":"claude","api":null,"error":{"stage":"http"}}
{"ts":3,"source":"claude","api":{"five_hour":{"utilization":55.4,"resets_at":"2026-01-01T00:00:00Z"},"seven_day":{"utilization":70.2,"resets_at":"2026-01-05T12:30:00.123456+00:00"}}}
{"ts":4,"source":"codex","codex_rate_limits":{}}
EOF
)"
run_refresh
assert_status "exits 0" 0 "$TH_STATUS"
IFS="$SEP" read -r five_pct got_five_epoch seven_pct got_seven_epoch <<< "$TH_OUT"
assert_eq "5h utilization rounds to nearest percent" "55" "$five_pct"
assert_eq "5h reset converts a plain Z timestamp to epoch" "$five_epoch" "$got_five_epoch"
assert_eq "7d utilization rounds to nearest percent" "70" "$seven_pct"
assert_eq "7d reset converts a fractional-second +00:00 timestamp to epoch" "$seven_epoch" "$got_seven_epoch"

section "row with no source key (pre-2026-08-30 legacy schema) still counts as Claude"
write_log '{"ts":1,"api":{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}}'
run_refresh
assert_status "exits 0" 0 "$TH_STATUS"
IFS="$SEP" read -r five_pct _ seven_pct _ <<< "$TH_OUT"
assert_eq "5h utilization read from a sourceless row" "12" "$five_pct"
assert_eq "7d utilization read from a sourceless row" "34" "$seven_pct"

section "the latest matching row wins, not the first"
write_log "$(cat <<EOF
{"ts":1,"source":"claude","api":{"five_hour":{"utilization":10},"seven_day":{"utilization":10}}}
{"ts":2,"source":"claude","api":{"five_hour":{"utilization":90},"seven_day":{"utilization":90}}}
EOF
)"
run_refresh
IFS="$SEP" read -r five_pct _ seven_pct _ <<< "$TH_OUT"
assert_eq "picks the later row's 5h percent" "90" "$five_pct"
assert_eq "picks the later row's 7d percent" "90" "$seven_pct"

section "log has claude_statusline push rows amid claude poll rows - only the poll row counts"
write_log "$(cat <<EOF
{"ts":1,"source":"claude","api":{"five_hour":{"utilization":20},"seven_day":{"utilization":20}}}
{"ts":2,"source":"claude_statusline","observed_at":999,"five_hour_pct":99,"seven_day_pct":99}
EOF
)"
run_refresh
assert_status "exits 0" 0 "$TH_STATUS"
IFS="$SEP" read -r five_pct _ seven_pct _ <<< "$TH_OUT"
assert_eq "ignores the claude_statusline row, reads the claude poll row" "20" "$five_pct"
assert_eq "same for 7d" "20" "$seven_pct"

section "missing utilization and null resets_at default cleanly"
write_log '{"ts":1,"source":"claude","api":{"five_hour":{},"seven_day":{"resets_at":null}}}'
run_refresh
assert_status "exits 0" 0 "$TH_STATUS"
IFS="$SEP" read -r five_pct five_reset seven_pct seven_reset <<< "$TH_OUT"
assert_eq "missing five_hour.utilization defaults to 0" "0" "$five_pct"
assert_eq "missing seven_day.utilization defaults to 0" "0" "$seven_pct"
assert_eq "missing five_hour.resets_at becomes an empty field" "" "$five_reset"
assert_eq "explicit null seven_day.resets_at becomes an empty field" "" "$seven_reset"

harness_summary
