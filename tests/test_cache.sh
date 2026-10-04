#!/bin/bash
# Unit tests for src/statusline/cache.sh - the lazy stale-while-revalidate
# primitives every provider adapter is built on. Each section gets its own
# isolated STATUSLINE_RUNTIME_DIR so tests never see each other's state.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

section "statusline_cache_init"
th_tmp_runtime
source "$REPO_ROOT/src/statusline/cache.sh"
statusline_cache_init
assert_file_exists "creates the state dir" "$STATUSLINE_STATE_DIR"
assert_file_exists "creates the locks dir" "$STATUSLINE_LOCK_DIR"

section "statusline_cache_is_fresh"
cf="$STATUSLINE_STATE_DIR/thing"
statusline_cache_is_fresh "$cf" 60 1000
assert_status "no timestamp: not fresh" 1 $?
printf '950\n' > "${cf}.timestamp"
statusline_cache_is_fresh "$cf" 60 1000
assert_status "within TTL: fresh" 0 $?
printf '900\n' > "${cf}.timestamp"
statusline_cache_is_fresh "$cf" 60 1000
assert_status "past TTL: not fresh" 1 $?
printf 'garbage\n' > "${cf}.timestamp"
statusline_cache_is_fresh "$cf" 60 1000
assert_status "non-numeric timestamp: not fresh" 1 $?

section "statusline_lock_acquire / statusline_lock_release"
statusline_lock_acquire mykey 5 1000
assert_status "first acquire succeeds" 0 $?
assert_eq "the lock file holds its creation epoch" "1000" "$(cat "$STATUSLINE_LOCK_DIR/mykey.lock")"
( statusline_lock_acquire mykey 5 1001 )
assert_status "second acquire on a fresh lock fails" 1 $?
statusline_lock_release
assert_file_missing "release removes the lock" "$STATUSLINE_LOCK_DIR/mykey.lock"
printf '100\n' > "$STATUSLINE_LOCK_DIR/stalekey.lock"
statusline_lock_acquire stalekey 5 1000
assert_status "a stale lock (past lock_stale_after) is taken over" 0 $?
assert_eq "...and now carries the new epoch" "1000" "$(cat "$STATUSLINE_LOCK_DIR/stalekey.lock")"
statusline_lock_release

section "statusline_refresh_if_stale: fresh cache short-circuits"
th_tmp_runtime
source "$REPO_ROOT/src/statusline/cache.sh"
statusline_cache_init
cf="$STATUSLINE_STATE_DIR/thing"
sentinel="$TH_TMP/ran"
printf 'cached-value\n' > "$cf"
printf '999\n' > "${cf}.timestamp"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "touch '$sentinel'; echo new-value"
assert_file_missing "fresh cache: refresh command never runs" "$sentinel"
assert_eq "fresh cache: value on disk is untouched" "cached-value" "$(cat "$cf")"

section "statusline_refresh_if_stale: stale cache, successful refresh"
printf '900\n' > "${cf}.timestamp"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "echo new-value"
assert_eq "successful refresh replaces the cache file" "new-value" "$(cat "$cf")"
assert_eq "successful refresh writes the new timestamp" "1000" "$(cat "${cf}.timestamp")"
assert_file_missing "successful refresh releases its lock" "$STATUSLINE_LOCK_DIR/thing-key.lock"

section "statusline_refresh_if_stale: a failure keeps old data and waits a full TTL"
printf '900\n' > "${cf}.timestamp"
: > "$sentinel"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "printf x >> '$sentinel'; exit 3"
assert_eq "failed refresh keeps the previous value" "new-value" "$(cat "$cf")"
assert_file_missing "no temp file left behind" "${cf}.tmp"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1001 bash -c "printf x >> '$sentinel'; exit 3"
assert_eq "not retried on the next render" "x" "$(cat "$sentinel")"
printf '900\n' > "${cf}.timestamp"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "true"
assert_eq "empty output counts as a failure too" "new-value" "$(cat "$cf")"

section "statusline_refresh_if_stale: a live lock held elsewhere defers instead of blocking"
printf '900\n' > "${cf}.timestamp"
rm -f "$sentinel"
printf '999\n' > "$STATUSLINE_LOCK_DIR/thing-key.lock"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "touch '$sentinel'; echo other"
assert_file_missing "a session that can't get the lock never runs the refresh command" "$sentinel"
assert_file_exists "someone else's lock is left alone" "$STATUSLINE_LOCK_DIR/thing-key.lock"
rm -f "$STATUSLINE_LOCK_DIR/thing-key.lock"

section "statusline_refresh_if_stale: hard timeout kills a hung refresh"
printf '900\n' > "${cf}.timestamp"
start="$(date +%s)"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "sleep 10; echo too-late"
elapsed=$(( $(date +%s) - start ))
assert_eq "a hung refresh is killed and the previous value is kept" "new-value" "$(cat "$cf")"
[ "$elapsed" -le 4 ]
assert_status "the 1s timeout is enforced (didn't wait for the 10s sleep)" 0 $?

section "statusline_write_quota_if_newer"
th_tmp_runtime
source "$REPO_ROOT/src/statusline/cache.sh"
statusline_cache_init
qc="$STATUSLINE_STATE_DIR/quota/claude"

statusline_write_quota_if_newer "$qc" 42 1700000000 55 1700100000 P 500
IFS="$STATUSLINE_FIELD_SEPARATOR" read -r v1 v2 v3 v4 v5 v6 < "$qc"
assert_eq "first write: 5h pct" "42" "$v1"
assert_eq "first write: 5h reset" "1700000000" "$v2"
assert_eq "first write: 7d pct" "55" "$v3"
assert_eq "first write: 7d reset" "1700100000" "$v4"
assert_eq "first write: source tag" "P" "$v5"
assert_eq "first write: observed_at" "500" "$v6"

statusline_write_quota_if_newer "$qc" 10 "" 20 "" X 400
IFS="$STATUSLINE_FIELD_SEPARATOR" read -r v1 _ _ _ v5 v6 < "$qc"
assert_eq "an older observed_at does not overwrite" "42" "$v1"
assert_eq "...source tag unchanged either" "P" "$v5"
assert_eq "...observed_at unchanged" "500" "$v6"

statusline_write_quota_if_newer "$qc" 10 "" 20 "" X 500
IFS="$STATUSLINE_FIELD_SEPARATOR" read -r v1 _ _ _ v5 _ < "$qc"
assert_eq "an equal observed_at does not overwrite either (strictly newer only)" "42" "$v1"
assert_eq "...source tag unchanged" "P" "$v5"

statusline_write_quota_if_newer "$qc" 99 1700200000 88 1700300000 X 600
IFS="$STATUSLINE_FIELD_SEPARATOR" read -r v1 v2 v3 v4 v5 v6 < "$qc"
assert_eq "a genuinely newer observed_at overwrites" "99" "$v1"
assert_eq "...every field, not just the tag" "1700200000" "$v2"
assert_eq "...source tag flips to the new writer" "X" "$v5"
assert_eq "...observed_at advances" "600" "$v6"

section "statusline_overlay_freshest_quota"
th_tmp_runtime
source "$REPO_ROOT/src/statusline/cache.sh"
statusline_cache_init
own="$STATUSLINE_STATE_DIR/quota/claude"
other="$TH_TMP/tracker-claude"
statusline_write_quota_if_newer "$own" 40 "" 50 "" X 500
statusline_write_quota_if_newer "$other" 41 "" 51 "" P 600
five_pct=""; week_pct=""
statusline_overlay_freshest_quota "$own" "$other"
assert_eq "the newer file wins, whichever argument it is" "41" "$five_pct"
statusline_write_quota_if_newer "$own" 42 "" 52 "" X 700
five_pct=""
statusline_overlay_freshest_quota "$own" "$other"
assert_eq "a stale second file never freezes the first" "42" "$five_pct"
statusline_write_quota_if_newer "$other" 43 "" 53 "" P 700
five_pct=""
statusline_overlay_freshest_quota "$own" "$other"
assert_eq "on a tie, the first argument wins" "42" "$five_pct"
five_pct="7"
statusline_overlay_freshest_quota "$own.missing" "$TH_TMP/also-missing"
assert_eq "no file at all: caller's values untouched" "7" "$five_pct"
printf 'garbage\n' > "$TH_TMP/garbage"
five_pct=""
statusline_overlay_freshest_quota "$TH_TMP/garbage" "$own"
assert_eq "an unreadable file never wins" "42" "$five_pct"

section "statusline_transcript_observed_at"
t="$TH_TMP/transcript.jsonl"
printf '%s\n' '{"type":"user","timestamp":"2026-01-01T10:00:00.000Z"}' \
    '{"type":"assistant","timestamp":"2026-01-01T10:00:05.500Z"}' '{"type":"summary"}' > "$t"
statusline_transcript_observed_at "$t" out
assert_eq "last assistant timestamp, skipping entries without one" "1767261605" "$out"
printf '%s\n' '{"type":"assistant","timestamp":"2026-01-01T10:00:05Z"}' \
    '{"type":"attachment","timestamp":"2026-01-03T00:00:00Z"}' '{"type":"user","timestamp":"2026-01-03T00:00:01Z"}' \
    '{"type":"ai-title"}' '{"type":"mode"}' > "$t"
statusline_transcript_observed_at "$t" out
assert_eq "later non-assistant entries don't make a stale reading look fresh" "1767261605" "$out"
{ printf 'x%.0s' $(seq 1 300000); printf '\n'; printf '%s\n' '{"type":"assistant","timestamp":"2026-01-01T10:00:05Z"}'; } > "$t"
statusline_transcript_observed_at "$t" out
assert_eq "a line cut by the 256 KB tail is skipped, not fatal" "1767261605" "$out"
printf '%s\n' '{"type":"assistant","timestamp":"2026-07-01T10:00:00.250Z"}' > "$t"
TZ=Europe/Paris statusline_transcript_observed_at "$t" out
assert_eq "exact UTC under a daylight-saving zone (jq 1.6 regression)" "1782900000" "$out"
printf '%s\n' '{"type":"assistant","timestamp":"2026-07-01T10:00:00+00:00"}' > "$t"
statusline_transcript_observed_at "$t" out
assert_eq "+00:00 suffix accepted" "1782900000" "$out"
printf '%s\n' '{"type":"user","timestamp":"2026-07-01T10:00:00Z"}' '{"type":"summary"}' > "$t"
statusline_transcript_observed_at "$t" out
assert_eq "no assistant message -> empty (unknown age)" "" "$out"
statusline_transcript_observed_at "$TH_TMP/nope.jsonl" out
assert_eq "missing transcript -> empty" "" "$out"

section "statusline_advance_spin_index"
th_tmp_runtime
source "$REPO_ROOT/src/statusline/cache.sh"
statusline_cache_init

statusline_advance_spin_index claude out
assert_eq "first call starts at 1 (no prior state)" "1" "$out"
statusline_advance_spin_index claude out
assert_eq "second call advances to 2" "2" "$out"

printf '9\n' > "$STATUSLINE_STATE_DIR/spin/claude"
statusline_advance_spin_index claude out
assert_eq "wraps from 9 back to 0" "0" "$out"

printf 'garbage\n' > "$STATUSLINE_STATE_DIR/spin/claude"
statusline_advance_spin_index claude out
assert_eq "a corrupt counter file resets to 1 instead of erroring" "1" "$out"

statusline_advance_spin_index codex codex_out
assert_eq "a different provider gets its own independent counter" "1" "$codex_out"
statusline_advance_spin_index claude out
assert_eq "...and doesn't disturb claude's own counter" "2" "$out"

section "statusline_read_host"
th_tmp_runtime
source "$REPO_ROOT/src/statusline/cache.sh"
statusline_cache_init
statusline_read_host
assert_eq "hostname read live" "$(hostname -s 2>/dev/null || hostname)" "$STATUSLINE_HOSTNAME"
assert_match "host color is numeric" "$STATUSLINE_HOST_COLOR" '^[0-9]+$'
assert_file_exists "color cached under the hostname" "$STATUSLINE_STATE_DIR/host-color/$STATUSLINE_HOSTNAME"
printf '77\n' > "$STATUSLINE_STATE_DIR/host-color/$STATUSLINE_HOSTNAME"
statusline_read_host
assert_eq "second read reuses the cached color" "77" "$STATUSLINE_HOST_COLOR"

harness_summary
