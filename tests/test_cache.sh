#!/bin/bash
# Unit tests for lib/statusline-cache.sh - the lazy stale-while-revalidate
# primitives every provider adapter is built on. Each section gets its own
# isolated STATUSLINE_RUNTIME_DIR so tests never see each other's state.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

section "statusline_cache_init"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
assert_file_exists "creates the state dir" "$STATUSLINE_STATE_DIR"
assert_file_exists "creates the locks dir" "$STATUSLINE_LOCK_DIR"
assert_file_exists "creates the logs dir" "$STATUSLINE_LOG_DIR"

section "statusline_cache_is_fresh"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
cf="$STATUSLINE_STATE_DIR/thing"
statusline_cache_is_fresh "$cf" 60 1000
assert_status "missing cache file: not fresh" 1 $?

printf 'v\n' > "$cf"
statusline_cache_is_fresh "$cf" 60 1000
assert_status "cache file with no timestamp sibling: not fresh" 1 $?

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
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
statusline_lock_acquire mykey 5 1000
assert_status "first acquire succeeds" 0 $?
assert_file_exists "lock dir created" "$STATUSLINE_LOCK_DIR/mykey.lock"

(
    STATUSLINE_LOCK_TOKEN=""
    STATUSLINE_LOCK_PATH=""
    statusline_lock_acquire mykey 5 1001
    exit $?
)
assert_status "second acquire on a fresh lock fails" 1 $?

statusline_lock_release
assert_file_missing "release with matching owner token removes the lock" "$STATUSLINE_LOCK_DIR/mykey.lock"

STATUSLINE_LOCK_TOKEN="not-the-owner"
mkdir -p "$STATUSLINE_LOCK_DIR/otherkey.lock"
printf 'someone-else\n' > "$STATUSLINE_LOCK_DIR/otherkey.lock/owner"
STATUSLINE_LOCK_PATH="$STATUSLINE_LOCK_DIR/otherkey.lock"
statusline_lock_release
assert_file_exists "release with mismatched owner token is a no-op" "$STATUSLINE_LOCK_DIR/otherkey.lock"
rm -rf "$STATUSLINE_LOCK_DIR/otherkey.lock"

mkdir -p "$STATUSLINE_LOCK_DIR/stalekey.lock"
printf 'someone\n' > "$STATUSLINE_LOCK_DIR/stalekey.lock/owner"
printf '100\n' > "$STATUSLINE_LOCK_DIR/stalekey.lock/timestamp"
statusline_lock_acquire stalekey 5 1000
assert_status "a stale lock (past lock_stale_after) can be stolen" 0 $?
new_owner="$(cat "$STATUSLINE_LOCK_DIR/stalekey.lock/owner")"
assert_eq "the stolen lock now carries the stealer's token" "$STATUSLINE_LOCK_TOKEN" "$new_owner"
statusline_lock_release

mkdir -p "$STATUSLINE_LOCK_DIR/freshkey.lock"
printf 'someone\n' > "$STATUSLINE_LOCK_DIR/freshkey.lock/owner"
printf '999\n' > "$STATUSLINE_LOCK_DIR/freshkey.lock/timestamp"
(
    STATUSLINE_LOCK_TOKEN=""
    STATUSLINE_LOCK_PATH=""
    statusline_lock_acquire freshkey 5 1000
    exit $?
)
assert_status "a fresh lock (within lock_stale_after) cannot be stolen" 1 $?
rm -rf "$STATUSLINE_LOCK_DIR/freshkey.lock"

section "statusline_refresh_if_stale: fresh cache short-circuits"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
cf="$STATUSLINE_STATE_DIR/thing"
sentinel="$TH_TMP/ran"
printf 'cached-value\n' > "$cf"
printf '999\n' > "${cf}.timestamp"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "touch '$sentinel'; echo new-value"
assert_file_missing "fresh cache: refresh command never runs" "$sentinel"
assert_eq "fresh cache: value on disk is untouched" "cached-value" "$(cat "$cf")"

section "statusline_refresh_if_stale: stale cache, successful refresh"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
cf="$STATUSLINE_STATE_DIR/thing"
printf 'old-value\n' > "$cf"
printf '900\n' > "${cf}.timestamp"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "echo new-value"
assert_eq "successful refresh replaces the cache file" "new-value" "$(cat "$cf")"
assert_eq "successful refresh writes the new timestamp" "1000" "$(cat "${cf}.timestamp")"
assert_file_missing "successful refresh clears the .attempted marker" "${cf}.attempted"
assert_file_missing "successful refresh releases its lock" "$STATUSLINE_LOCK_DIR/thing-key.lock"
assert_contains "successful refresh is logged" "$(cat "$STATUSLINE_LOG_DIR/statusline.log")" "refresh_success"

section "statusline_refresh_if_stale: stale cache, failing refresh keeps old data"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
cf="$STATUSLINE_STATE_DIR/thing"
printf 'old-value\n' > "$cf"
printf '900\n' > "${cf}.timestamp"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "echo bad >&2; exit 3"
assert_eq "failed refresh keeps the stale value on disk" "old-value" "$(cat "$cf")"
assert_eq "failed refresh keeps the old timestamp" "900" "$(cat "${cf}.timestamp")"
assert_file_exists "failed refresh leaves an .attempted marker" "${cf}.attempted"
assert_contains "failure is logged with its exit code" "$(cat "$STATUSLINE_LOG_DIR/statusline.log")" "exit=3"
assert_contains "failure log captures stale_age" "$(cat "$STATUSLINE_LOG_DIR/statusline.log")" "stale_age=100s"

section "statusline_refresh_if_stale: a live lock held elsewhere defers instead of blocking"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
cf="$STATUSLINE_STATE_DIR/thing"
sentinel="$TH_TMP/ran"
printf 'old-value\n' > "$cf"
printf '900\n' > "${cf}.timestamp"
mkdir -p "$STATUSLINE_LOCK_DIR/thing-key.lock"
printf 'someone-else\n' > "$STATUSLINE_LOCK_DIR/thing-key.lock/owner"
printf '999\n' > "$STATUSLINE_LOCK_DIR/thing-key.lock/timestamp"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "touch '$sentinel'; echo new-value"
assert_file_missing "a session that can't get the lock never runs the refresh command" "$sentinel"
assert_eq "the stale value is rendered as-is while another session owns the lock" "old-value" "$(cat "$cf")"
assert_file_exists "someone else's lock is left alone, not deleted" "$STATUSLINE_LOCK_DIR/thing-key.lock"
rm -rf "$STATUSLINE_LOCK_DIR/thing-key.lock"

section "statusline_refresh_if_stale: recently-failed attempts are throttled, not retried every render"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
cf="$STATUSLINE_STATE_DIR/thing"
sentinel="$TH_TMP/run-count"
printf 'old-value\n' > "$cf"
printf '900\n' > "${cf}.timestamp"
: > "$sentinel"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "printf x >> '$sentinel'; exit 1"
assert_eq "first attempt runs the command once" "x" "$(cat "$sentinel")"
statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1001 bash -c "printf x >> '$sentinel'; exit 1"
assert_eq "a second call one second later (still within TTL, lock already released) does not retry" "x" "$(cat "$sentinel")"

section "statusline_refresh_if_stale: hard timeout kills a hung refresh"
if command -v perl >/dev/null 2>&1; then
    th_tmp_runtime
    source "$REPO_ROOT/lib/statusline-cache.sh"
    statusline_cache_init
    cf="$STATUSLINE_STATE_DIR/thing"
    printf 'old-value\n' > "$cf"
    printf '900\n' > "${cf}.timestamp"
    start="$(date +%s)"
    statusline_refresh_if_stale "$cf" 60 thing-key 5 1 1000 bash -c "sleep 10; echo too-late"
    elapsed=$(( $(date +%s) - start ))
    assert_eq "a hung refresh is killed and the stale value is kept" "old-value" "$(cat "$cf")"
    [ "$elapsed" -le 4 ]
    assert_status "the 1s timeout is enforced (didn't wait for the 10s sleep)" 0 $?
else
    section "  (skipped: perl not on PATH, timeout enforcement can't run)"
fi

section "statusline_write_values_if_stale"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
cf="$STATUSLINE_STATE_DIR/values"
statusline_write_values_if_stale "$cf" 60 values-key 5 1000 a b c
IFS="$STATUSLINE_FIELD_SEPARATOR" read -r v1 v2 v3 < "$cf"
assert_eq "writes field-separated values" "a" "$v1"
assert_eq "writes field-separated values (2nd)" "b" "$v2"
assert_eq "writes field-separated values (3rd)" "c" "$v3"
assert_eq "writes the timestamp" "1000" "$(cat "${cf}.timestamp")"

statusline_write_values_if_stale "$cf" 60 values-key 5 1010 x y z
assert_eq "fresh cache: write is skipped, old values remain" "a${STATUSLINE_FIELD_SEPARATOR}b${STATUSLINE_FIELD_SEPARATOR}c" "$(cat "$cf")"

section "statusline_read_static"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
statusline_read_static
assert_file_exists "generates the hostname file on first read" "$STATUSLINE_STATE_DIR/static/hostname"
assert_file_exists "generates the host-color file on first read" "$STATUSLINE_STATE_DIR/static/host-color"
assert_ne "picks a non-empty hostname" "" "$STATUSLINE_HOSTNAME"
assert_match "host color is numeric" "$STATUSLINE_HOST_COLOR" '^[0-9]+$'

printf 'fixed-host\n' > "$STATUSLINE_STATE_DIR/static/hostname"
printf '77\n' > "$STATUSLINE_STATE_DIR/static/host-color"
statusline_read_static
assert_eq "second read reuses the file, doesn't regenerate" "fixed-host" "$STATUSLINE_HOSTNAME"
assert_eq "second read reuses the color file" "77" "$STATUSLINE_HOST_COLOR"

section "statusline_git_cache_paths"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
statusline_git_cache_paths "/Users/dev/my-project"
assert_eq "cache key replaces slashes with dashes" "cwd-Users-dev-my-project" "$STATUSLINE_GIT_KEY"
assert_eq "local cache path scoped to the cwd" "$STATUSLINE_STATE_DIR/git/cwd/Users/dev/my-project/local" "$STATUSLINE_GIT_LOCAL_CACHE"
assert_eq "remote cache path scoped to the cwd" "$STATUSLINE_STATE_DIR/git/cwd/Users/dev/my-project/remote" "$STATUSLINE_GIT_REMOTE_CACHE"

section "log rotation"
th_tmp_runtime
source "$REPO_ROOT/lib/statusline-cache.sh"
statusline_cache_init
STATUSLINE_LOG_MAX_BYTES=100
head -c 200 /dev/zero | tr '\0' 'x' > "$STATUSLINE_LOG_FILE"
statusline_log_event 1000 some_event "detail"
assert_file_exists "oversized log is rotated to .1" "${STATUSLINE_LOG_FILE}.1"
assert_contains "the new log starts fresh with the latest event" "$(cat "$STATUSLINE_LOG_FILE")" "some_event"

harness_summary
