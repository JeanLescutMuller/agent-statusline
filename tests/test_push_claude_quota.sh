#!/bin/bash
# End-to-end tests for lib/statusline-push-claude-quota.sh - the free path
# that appends a claude_statusline row to the shared quota log from the
# statusline's own stdin rate_limits, instead of waiting on
# quota/poll_claude.py's network poll. See the script's own header comment
# and quota/AGENTS.md's "GET /api/oauth/usage 429s" investigation for why.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

PUSH="$REPO_ROOT/lib/statusline-push-claude-quota.sh"
TH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-pushhome.XXXXXX")"
trap 'rm -rf "$TH_HOME"' EXIT
LOG="$TH_HOME/opt/agent-statusline/data/utilization-log.jsonl"
TRANSCRIPT="$TH_HOME/transcript.jsonl"

write_log() { mkdir -p "$(dirname "$LOG")"; printf '%s\n' "$1" > "$LOG"; }
write_transcript() { printf '%s\n' "$1" > "$TRANSCRIPT"; }
row_count() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

run_push() {
    local err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    TH_OUT="$(HOME="$TH_HOME" bash "$PUSH" "$@" 2>"$err_file")"
    TH_STATUS=$?
    TH_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}

section "no transcript path at all -> no-op"
rm -f "$LOG"
run_push "" 42 "2026-01-01T00:00:00Z" 55 "2026-01-05T00:00:00Z"
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "nothing logged" "$LOG"

section "transcript path doesn't exist -> no-op"
run_push "$TH_HOME/nope.jsonl" 42 "" 55 ""
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "nothing logged" "$LOG"

section "transcript exists but has no timestamped lines -> no-op"
write_transcript '{"type":"summary","leafUuid":"x"}'
run_push "$TRANSCRIPT" 42 "" 55 ""
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "nothing logged" "$LOG"

section "first genuine reading -> appends one row"
write_transcript "$(cat <<'EOF'
{"type":"user","timestamp":"2026-01-01T10:00:00.000Z"}
{"type":"assistant","timestamp":"2026-01-01T10:00:05.500Z"}
{"type":"summary","leafUuid":"x"}
EOF
)"
run_push "$TRANSCRIPT" 42 "2026-01-01T15:00:00Z" 55 "2026-01-08T00:00:00Z"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "exactly one row logged" "1" "$(row_count)"
row="$(cat "$LOG")"
assert_contains "tagged claude_statusline" "$row" '"source":"claude_statusline"'
assert_contains "carries the five-hour percent" "$row" '"five_hour_pct":42'
assert_contains "carries the seven-day percent" "$row" '"seven_day_pct":55'
assert_contains "carries the five-hour reset" "$row" '"five_hour_resets_at":"2026-01-01T15:00:00Z"'
assert_contains "observed_at is the transcript's last timestamp, not append time" \
    "$row" '"observed_at":1767261605'

section "same transcript again -> no new row (observed_at not newer)"
run_push "$TRANSCRIPT" 42 "2026-01-01T15:00:00Z" 55 "2026-01-08T00:00:00Z"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "still exactly one row" "1" "$(row_count)"

section "a genuinely newer transcript entry -> appends a second row"
cat >> "$TRANSCRIPT" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T10:05:00.000Z"}
EOF
run_push "$TRANSCRIPT" 43 "2026-01-01T15:00:00Z" 55 "2026-01-08T00:00:00Z"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "two rows now" "2" "$(row_count)"

section "empty resets_at fields become JSON null, not empty strings"
write_transcript '{"type":"assistant","timestamp":"2026-02-01T00:00:00.000Z"}'
rm -f "$LOG"
run_push "$TRANSCRIPT" 10 "" 20 ""
row="$(cat "$LOG")"
assert_contains "five_hour_resets_at is null" "$row" '"five_hour_resets_at":null'
assert_contains "seven_day_resets_at is null" "$row" '"seven_day_resets_at":null'

section "intervening claude/codex poll rows don't confuse the per-source comparison"
rm -f "$LOG"
write_transcript '{"type":"assistant","timestamp":"2026-03-01T00:00:00.000Z"}'
run_push "$TRANSCRIPT" 10 "" 20 ""  # seeds one claude_statusline row
cat >> "$LOG" <<'EOF'
{"ts":1,"source":"claude","api":{}}
{"ts":2,"source":"codex","codex_rate_limits":{}}
EOF
# Same transcript timestamp as the seed row - should still no-op despite the
# two unrelated rows now sitting at the tail of the file (poll_claude.py hit
# exactly this class of bug once: reading only the literal last line instead
# of the last row from the same source - see quota/AGENTS.md).
run_push "$TRANSCRIPT" 10 "" 20 ""
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "still exactly 3 rows (seed + 2 unrelated), no duplicate push" "3" "$(row_count)"

harness_summary
