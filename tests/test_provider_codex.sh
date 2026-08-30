#!/bin/bash
# End-to-end tests for providers/codex-statusline-command.sh. Same isolation
# strategy as test_provider_claude.sh (HOME override + STATUSLINE_RUNTIME_DIR
# override), but the Codex adapter picks its jq `now` from the real wall
# clock (not the payload), so page selection can't be forced deterministically
# - the carousel-dependent sections poll for real (bounded, ~13s worst case)
# until the page they need shows up.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

PROVIDER="$REPO_ROOT/providers/codex-statusline-command.sh"
FIXTURES="$TESTS_DIR/fixtures"
POLL_DEADLINE_SECONDS=13

th_tmp_runtime
TH_HOME="$(mktemp -d "$TH_TMP/home.XXXXXX")"
TH_HOME="$(cd "$TH_HOME" && pwd -P)"

run_codex() {
    local payload_file="$1" cwd="$2" err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    TH_OUT="$(sed "s#__CWD__#$cwd#" "$payload_file" | HOME="$TH_HOME" bash "$PROVIDER" 2>"$err_file")"
    TH_STATUS=$?
    TH_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}

# wait_for_page <payload_file> <cwd> <icon> - polls until a call's output
# contains $icon (identifying which of the 3 carousel pages it is), or the
# deadline passes. Result lands in WAIT_RESULT ("" if never seen).
wait_for_page() {
    local payload_file="$1" cwd="$2" icon="$3" deadline
    WAIT_RESULT=""
    deadline=$(( $(date +%s) + POLL_DEADLINE_SECONDS ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        run_codex "$payload_file" "$cwd"
        case "$TH_OUT" in
            *"$icon"*) WAIT_RESULT="$TH_OUT"; return ;;
        esac
        sleep 0.5
    done
}

plain_dir="$TH_HOME/plain"
mkdir -p "$plain_dir"

section "single call renders exactly one recognizable page"
run_codex "$FIXTURES/codex-payload.json" "$plain_dir"
assert_status "exits 0" 0 "$TH_STATUS"
line_count="$(printf '%s\n' "$TH_OUT" | wc -l | tr -d ' ')"
assert_eq "renders exactly one line (one carousel page)" "1" "$line_count"
assert_match "output is page 1, 2, or 3's known shape" "$TH_OUT" '🤖|🆔|💬'

section "quota cache is seeded from the payload's rate_limits"
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime2.XXXXXX")"
run_codex "$FIXTURES/codex-payload.json" "$plain_dir"
quota_cache="$STATUSLINE_RUNTIME_DIR/state/providers/codex"
assert_file_exists "quota cache written from the payload" "$quota_cache"
assert_contains "cached value matches the payload's 5h percent" "$(cat "$quota_cache")" "20"

section "carousel: page 1 (model/host/cwd)"
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime3.XXXXXX")"
wait_for_page "$FIXTURES/codex-payload.json" "$plain_dir" "🤖"
assert_ne "page 1 was observed within ${POLL_DEADLINE_SECONDS}s" "" "$WAIT_RESULT"
assert_contains "page 1 shows the model + reasoning" "$WAIT_RESULT" "codex-large (high)"
assert_contains "page 1 shows the cwd" "$WAIT_RESULT" "plain"

section "carousel: page 2 (thread id / security) + Read Only + Approve for me"
wait_for_page "$FIXTURES/codex-payload.json" "$plain_dir" "🆔"
assert_ne "page 2 was observed within ${POLL_DEADLINE_SECONDS}s" "" "$WAIT_RESULT"
assert_contains "page 2 shows the thread id" "$WAIT_RESULT" "thread-1"
assert_contains "page 2 shows the thread title" "$WAIT_RESULT" "Fix the bug"
assert_contains "'Read Only' + 'Approve for me' remap to Read/Auto" "$WAIT_RESULT" "Read/Auto"

section "carousel: page 3 (bars)"
wait_for_page "$FIXTURES/codex-payload.json" "$plain_dir" "💬"
assert_ne "page 3 was observed within ${POLL_DEADLINE_SECONDS}s" "" "$WAIT_RESULT"
assert_contains "page 3 shows the context percentage" "$WAIT_RESULT" "30%"
assert_contains "page 3 shows the 5h percentage" "$WAIT_RESULT" "20%"
assert_contains "page 3 shows the 7d/weekly percentage" "$WAIT_RESULT" "45%"

section "permissions/approval remap: Full Access + Ask for approval"
wait_for_page "$FIXTURES/codex-payload-full-ask.json" "$plain_dir" "🆔"
assert_ne "page 2 was observed within ${POLL_DEADLINE_SECONDS}s" "" "$WAIT_RESULT"
assert_contains "'Full Access' + 'Ask for approval' remap to Full/Ask" "$WAIT_RESULT" "Full/Ask"

section "permissions/approval remap: Custom permissions + Approve for me"
wait_for_page "$FIXTURES/codex-payload-custom.json" "$plain_dir" "🆔"
assert_ne "page 2 was observed within ${POLL_DEADLINE_SECONDS}s" "" "$WAIT_RESULT"
assert_contains "'Custom permissions' remaps to Custom" "$WAIT_RESULT" "Custom/Auto"

section "minimal payload (no thread_title, no rate_limits)"
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime4.XXXXXX")"
run_codex "$FIXTURES/codex-payload-full-ask.json" "$plain_dir"
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "no rate_limits in the payload: quota cache not written" \
    "$STATUSLINE_RUNTIME_DIR/state/providers/codex"

harness_summary
