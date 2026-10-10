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
want=$(if [ "$(uname)" = Darwin ]; then scutil --get HostName; else cat /etc/hostname; fi 2>/dev/null); want=${want%%.*}
assert_eq "hostname: the machine's name (\"Machine name\" in ~/AGENTS.md)" "$want" "$STATUSLINE_HOSTNAME"
JR_MACHINE_NAME=box.example statusline_read_host
assert_eq "hostname: JR_MACHINE_NAME first, cut at the first dot" "box" "$STATUSLINE_HOSTNAME"
JR_MACHINE_NAME='a b' statusline_read_host
assert_eq "hostname: no valid name shows ?" "?" "$STATUSLINE_HOSTNAME"
statusline_read_host
assert_match "host color is numeric" "$STATUSLINE_HOST_COLOR" '^[0-9]+$'
assert_file_exists "color cached under the hostname" "$STATUSLINE_STATE_DIR/host-color/$STATUSLINE_HOSTNAME"
printf '77\n' > "$STATUSLINE_STATE_DIR/host-color/$STATUSLINE_HOSTNAME"
statusline_read_host
assert_eq "second read reuses the cached color" "77" "$STATUSLINE_HOST_COLOR"

harness_summary
