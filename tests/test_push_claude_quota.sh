#!/bin/bash
# End-to-end tests for src/statusline/push-claude-quota.sh - the free path
# that (1) appends a claude_statusline row to the shared history log from
# the statusline's own stdin rate_limits, whenever the transcript gives a
# precise timestamp, and (2) always updates the shared "latest known quota"
# state file (tagged X) - using that same precise timestamp when available,
# or "now" as a fallback otherwise - instead of waiting on
# src/quota_polling/poll_claude.py's network poll. See the script's own
# header comment and adhoc_quotas_analysis/AGENTS.md's "GET /api/oauth/usage
# 429s" investigation for why the free path exists at all.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

PUSH="$REPO_ROOT/src/statusline/push-claude-quota.sh"
SEP=$'\034'
TH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-pushhome.XXXXXX")"
trap 'rm -rf "$TH_HOME"' EXIT
SESSION_DIR="$TH_HOME/opt/agent-statusline/data/claude"
LOG="$SESSION_DIR/account.jsonl"
STATE="$TH_HOME/opt/agent-statusline/state/quota/claude"
TRANSCRIPT="$TH_HOME/transcript.jsonl"

write_log() { mkdir -p "$(dirname "$LOG")"; printf '%s\n' "$1" > "$LOG"; }
write_transcript() { printf '%s\n' "$1" > "$TRANSCRIPT"; }
row_count() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
reset() { rm -rf "$SESSION_DIR" "$STATE"; }

run_push() {
    local err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    TH_OUT="$(HOME="$TH_HOME" bash "$PUSH" "$@" 2>"$err_file")"
    TH_STATUS=$?
    TH_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}

section "no five_pct at all -> true no-op, nothing written anywhere"
reset
run_push "" "" "" "" ""
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "nothing logged" "$LOG"
assert_file_missing "state file untouched" "$STATE"

section "no transcript_path -> log untouched, state file still written via a now fallback"
reset
before="$(date +%s)"
run_push "" 42 "2026-01-01T00:00:00Z" 55 "2026-01-05T00:00:00Z"
after="$(date +%s)"
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "no precise timestamp, so no history row" "$LOG"
assert_file_exists "state file written anyway - still a live reading" "$STATE"
IFS="$SEP" read -r st_five st_five_reset st_week st_week_reset st_source st_observed < "$STATE"
assert_eq "state 5h percent" "42" "$st_five"
assert_eq "state tagged X" "X" "$st_source"
[ "$st_observed" -ge "$before" ] && [ "$st_observed" -le "$after" ]
assert_status "observed_at falls back to roughly now" 0 $?

section "transcript path doesn't exist -> same fallback behavior"
reset
run_push "$TH_HOME/nope.jsonl" 42 "" 55 ""
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "no history row" "$LOG"
assert_file_exists "state file still written" "$STATE"

section "transcript exists but has no timestamped lines -> same fallback behavior"
reset
write_transcript '{"type":"summary","leafUuid":"x"}'
run_push "$TRANSCRIPT" 42 "" 55 ""
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "no history row" "$LOG"
assert_file_exists "state file still written" "$STATE"

section "first genuine reading (valid transcript) -> a precise history row and state write"
reset
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
assert_file_exists "state file written" "$STATE"
IFS="$SEP" read -r st_five st_five_reset st_week st_week_reset st_source st_observed < "$STATE"
assert_eq "state 5h percent" "42" "$st_five"
assert_eq "state 5h reset" "2026-01-01T15:00:00Z" "$st_five_reset"
assert_eq "state 7d percent" "55" "$st_week"
assert_eq "state 7d reset" "2026-01-08T00:00:00Z" "$st_week_reset"
assert_eq "state tagged X (push)" "X" "$st_source"
assert_eq "state observed_at matches the log row's precise timestamp" "1767261605" "$st_observed"

section "same transcript again -> the log has no dedup any more, appends regardless"
run_push "$TRANSCRIPT" 42 "2026-01-01T15:00:00Z" 55 "2026-01-08T00:00:00Z"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "a second, duplicate-looking row is appended" "2" "$(row_count)"

section "a genuinely newer transcript entry -> appends a third row"
cat >> "$TRANSCRIPT" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T10:05:00.000Z"}
EOF
run_push "$TRANSCRIPT" 43 "2026-01-01T15:00:00Z" 55 "2026-01-08T00:00:00Z"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "three rows now" "3" "$(row_count)"
IFS="$SEP" read -r st_five _ _ _ _ st_observed < "$STATE"
assert_eq "state file picks up the newer 5h percent" "43" "$st_five"
assert_eq "state file's observed_at advances too" "1767261900" "$st_observed"

section "an older/equal observed_at does not regress the state file"
run_push "$TRANSCRIPT" 99 "2026-01-01T15:00:00Z" 55 "2026-01-08T00:00:00Z"
# Same transcript (same last timestamp, observed_at unchanged) but a
# different five_pct - if the state file compared correctly it stays at 43,
# not 99, even though the log itself still appends unconditionally.
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "four rows in the log (still no dedup there)" "4" "$(row_count)"
IFS="$SEP" read -r st_five _ _ _ _ _ < "$STATE"
assert_eq "state file 5h percent unchanged (99 was not newer)" "43" "$st_five"

section "empty resets_at fields become JSON null, not empty strings"
reset
write_transcript '{"type":"assistant","timestamp":"2026-02-01T00:00:00.000Z"}'
run_push "$TRANSCRIPT" 10 "" 20 ""
row="$(cat "$LOG")"
assert_contains "five_hour_resets_at is null" "$row" '"five_hour_resets_at":null'
assert_contains "seven_day_resets_at is null" "$row" '"seven_day_resets_at":null'

section "observed_at is exact UTC even when the local zone is in daylight-saving time"
# Regression test: jq 1.6's fromdateiso8601 on macOS returned an epoch one
# hour too late for a summer timestamp under a DST zone such as Europe/Paris.
reset
write_transcript '{"type":"assistant","timestamp":"2026-07-01T10:00:00.250Z"}'
TZ=Europe/Paris run_push "$TRANSCRIPT" 10 "" 20 ""
assert_contains "summer timestamp under Europe/Paris" "$(cat "$LOG")" '"observed_at":1782900000'
reset
write_transcript '{"type":"assistant","timestamp":"2026-07-01T10:00:00+00:00"}'
TZ=America/New_York run_push "$TRANSCRIPT" 10 "" 20 ""
assert_contains "+00:00 suffix under America/New_York" "$(cat "$LOG")" '"observed_at":1782900000'

section "float percents -> logged unrounded, state file gets them rounded"
reset
write_transcript '{"type":"assistant","timestamp":"2026-03-01T00:00:00.000Z"}'
run_push "$TRANSCRIPT" 23.5 "" 41.2 ""
assert_status "exits 0" 0 "$TH_STATUS"
row="$(cat "$LOG")"
assert_contains "five-hour percent keeps its fraction" "$row" '"five_hour_pct":23.5'
assert_contains "seven-day percent keeps its fraction" "$row" '"seven_day_pct":41.2'
IFS="$SEP" read -r st_five _ st_week _ _ _ < "$STATE"
assert_eq "state 5h percent rounded" "24" "$st_five"
assert_eq "state 7d percent rounded" "41" "$st_week"

section "session fields -> session file only; account row gets observed_by_session, never cost"
reset
write_transcript '{"type":"assistant","timestamp":"2026-03-01T00:00:00.000Z"}'
run_push "$TRANSCRIPT" 10 "" 20 "" "sess-1" 0.01234 "" "claude-opus-5-5"
row="$(cat "$LOG")"
assert_eq "account row names the observing session" "sess-1" "$(printf '%s' "$row" | jq -r .observed_by_session)"
assert_not_contains "account row carries no cost" "$row" "session_cost_usd"
assert_not_contains "account row has no bare session_id" "$row" '"session_id"'
srow="$(cat "$SESSION_DIR/sess-1.jsonl")"
assert_eq "one session row" "1" "$(wc -l < "$SESSION_DIR/sess-1.jsonl" | tr -d ' ')"
assert_eq "cumulative session cost in the session file" "0.01234" "$(printf '%s' "$srow" | jq -c .session_cost_usd)"
assert_eq "model id in the session file" "claude-opus-5-5" "$(printf '%s' "$srow" | jq -r .model_id)"
assert_eq "same observed_at in both scopes (the join key)" \
    "$(printf '%s' "$row" | jq .observed_at)" "$(printf '%s' "$srow" | jq .observed_at)"
assert_eq "session row has no percent under any name" "" \
    "$(printf '%s' "$srow" | jq -r '[paths | map(tostring) | join(".") | select(test("pct|percent|utiliz"; "i"))] | join(",")')"
reset
run_push "$TRANSCRIPT" 10 "" 20 ""
assert_contains "no session id -> observed_by_session null" "$(cat "$LOG")" '"observed_by_session":null'
assert_eq "no session id -> no session file" "0" "$(ls "$SESSION_DIR" | grep -vc '^account.jsonl$')"

section "a session id that isn't a plain token never becomes a file name"
reset
run_push "$TRANSCRIPT" 10 "" 20 "" "../escape" 0.5
assert_eq "account row still written" "1" "$(row_count)"
assert_eq "no session file anywhere" "0" "$(find "$TH_HOME" -name '*escape*' | wc -l | tr -d ' ')"
run_push "$TRANSCRIPT" 10 "" 20 "" "account" 0.5
assert_eq "the reserved name 'account' is refused too - account.jsonl holds only account rows" "0" \
    "$(grep -c session_cost_usd "$LOG")"

section "prompt_cache -> session file, as the raw object, null when absent or invalid"
reset
run_push "$TRANSCRIPT" 10 "" 20 "" "sess-1" 0.5 '{"warm":true,"misses":2,"miss_causes":{"system_prompt_changed":2},"hit_ratio":0.83}'
assert_eq "prompt_cache object logged unchanged" '{"warm":true,"misses":2,"miss_causes":{"system_prompt_changed":2},"hit_ratio":0.83}' \
    "$(jq -c .prompt_cache "$SESSION_DIR/sess-1.jsonl")"
assert_not_contains "never in the account row" "$(cat "$LOG")" "prompt_cache"
reset
run_push "$TRANSCRIPT" 10 "" 20 "" "sess-1" 0.5 ""
assert_contains "absent -> null" "$(cat "$SESSION_DIR/sess-1.jsonl")" '"prompt_cache":null'
reset
run_push "$TRANSCRIPT" 10 "" 20 "" "sess-1" 0.5 "not json"
assert_contains "invalid JSON -> null, row still written" "$(cat "$SESSION_DIR/sess-1.jsonl")" '"prompt_cache":null'

harness_summary
