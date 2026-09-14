#!/bin/bash
# End-to-end tests for providers/claude-statusline-command.sh, following the
# README's "Offline testing" recipe: STATUSLINE_RUNTIME_DIR/STATUSLINE_LIB_DIR
# point at an isolated temp runtime, and a captured payload is piped in.
#
# HOME is also overridden per call. push-claude-quota.sh (invoked as a
# subprocess whenever the payload has rate_limits - see
# test_push_claude_quota.sh for that script's own tests) hardcodes
# $HOME/opt/agent-statusline/data/claude-quota-history.jsonl, and
# statusline_read_static falls back to $HOME/opt/bootstrap-home/bin/get_host_color
# - pointing HOME at an empty temp dir makes both misses deterministic
# instead of quietly depending on what's installed on the machine running
# the suite.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

PROVIDER="$REPO_ROOT/providers/claude-statusline-command.sh"
FIXTURES="$TESTS_DIR/fixtures"

th_tmp_runtime
TH_HOME="$(mktemp -d "$TH_TMP/home.XXXXXX")"
TH_HOME="$(cd "$TH_HOME" && pwd -P)"

run_claude() {
    local payload_file="$1" cwd="$2" err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    TH_OUT="$(sed "s#__CWD__#$cwd#" "$payload_file" | HOME="$TH_HOME" bash "$PROVIDER" 2>"$err_file")"
    TH_STATUS=$?
    TH_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}

git_repo="$TH_HOME/proj"
mkdir -p "$git_repo"
git -C "$git_repo" init --quiet --initial-branch=main
git -C "$git_repo" config user.email test@example.com
git -C "$git_repo" config user.name Test
printf 'x\n' > "$git_repo/file.txt"
git -C "$git_repo" add file.txt
git -C "$git_repo" commit --quiet -m initial

plain_dir="$TH_HOME/plain"
mkdir -p "$plain_dir"

section "full payload in a git repo"
run_claude "$FIXTURES/claude-payload.json" "$git_repo"
assert_status "exits 0" 0 "$TH_STATUS"
line_count="$(printf '%s\n' "$TH_OUT" | wc -l | tr -d ' ')"
assert_eq "renders exactly three lines" "3" "$line_count"
assert_contains "line 1 shows model + effort" "$TH_OUT" "Opus (high)"
assert_contains "line 1 collapses the cwd under HOME to ~" "$TH_OUT" "~/proj"
assert_contains "line 1 shows the git branch" "$TH_OUT" "🌿 main"
assert_contains "line 2 shows the session id" "$TH_OUT" "session-abc123"
assert_contains "line 2 shows the resets summary" "$TH_OUT" "Resets: "
assert_match "line 2 ends with a braille spinner glyph" "$TH_OUT" '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'

section "the spinner advances every render, independent of wall-clock time"
# Regression test: this used to key the spinner frame off `now % 10`, which
# visibly froze under Claude Code's own default statusLine refreshInterval
# of 10s (consecutive renders land ~10s apart, so `now % 10` kept landing on
# the same remainder). Two renders in immediate succession - same wall-clock
# second, quite possibly - must still show two different frames.
extract_spinner() { printf '%s\n' "$1" | sed -n '2p' | grep -oE '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' | tail -1; }
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime-spin.XXXXXX")"
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
spin_a="$(extract_spinner "$TH_OUT")"
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
spin_b="$(extract_spinner "$TH_OUT")"
assert_ne "back-to-back renders show different spinner frames" "$spin_a" "$spin_b"
assert_contains "line 3 shows the context percentage" "$TH_OUT" "42%"
assert_contains "line 3 shows the 5h percentage" "$TH_OUT" "55%"
assert_contains "line 3 shows the 7d percentage" "$TH_OUT" "70%"
assert_contains "5h is tagged X - this render's own push, read back immediately" "$TH_OUT" "55% (X)"
assert_contains "7d is tagged X too" "$TH_OUT" "70% (X)"

section "full payload outside a git repo"
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
assert_not_contains "no git segment when cwd isn't a repo" "$TH_OUT" "🌿"
assert_contains "cwd is still shown and collapsed" "$TH_OUT" "~/plain"

section "minimal payload (nulls/missing fields)"
run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "model defaults to Claude" "$TH_OUT" "🤖 Claude"
assert_contains "context defaults to 0%" "$TH_OUT" "0%"

section "quota cache write-through and reuse"
# A fresh STATUSLINE_RUNTIME_DIR (nested under the same trapped TH_TMP, no
# new trap) so this section starts with no pre-existing quota cache from the
# sections above.
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime2.XXXXXX")"
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
quota_cache="$STATUSLINE_RUNTIME_DIR/state/quota/claude"
assert_file_exists "first call creates the state file from the payload's own push" "$quota_cache"
assert_contains "cached value matches the payload's 5h percent" "$(cat "$quota_cache")" "55"
assert_file_exists "every render touches the liveness heartbeat src/quota_polling/poll_claude.py polls faster against" \
    "$STATUSLINE_RUNTIME_DIR/state/heartbeat/claude"

run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_contains "a later call with no rate_limits in the payload still shows the cached 5h percent" "$TH_OUT" "55%"
assert_contains "...and the cached 7d percent" "$TH_OUT" "70%"
assert_contains "...still tagged X, from the earlier render's push" "$TH_OUT" "55% (X)"

section "concurrent sessions converge on whichever reading is freshest"
# Reproduces the scenario this design fixes: three "sessions" each with
# their own live rate_limits (all tagged X, per above) used to each just
# show their own last-known number - now they all read the same state file
# back, so whichever pushed most recently wins for everyone, not just for
# itself.
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime3.XXXXXX")"
quota_cache="$STATUSLINE_RUNTIME_DIR/state/quota/claude"

payload_for() {
    local pct="$1" ts="$2" out="$3" transcript
    transcript="$TH_TMP/transcript-$pct.jsonl"
    printf '{"type":"assistant","timestamp":"%s"}\n' "$ts" > "$transcript"
    sed "s#__CWD__#$plain_dir#" "$FIXTURES/claude-payload.json" \
        | jq --arg t "$transcript" --argjson p "$pct" \
            '. + {transcript_path: $t, rate_limits: (.rate_limits + {five_hour: {used_percentage: $p, resets_at: 1788091200}})}' \
        > "$out"
}

# Session A's last message was earliest; B's later; C hasn't sent one yet.
payload_for 24 "2026-01-01T00:00:00.000Z" "$TH_TMP/payload-a.json"
payload_for 25 "2026-01-01T00:05:00.000Z" "$TH_TMP/payload-b.json"

run_claude "$TH_TMP/payload-a.json" "$plain_dir"
assert_contains "session A shows its own 24%" "$TH_OUT" "24% (X)"

run_claude "$TH_TMP/payload-b.json" "$plain_dir"
assert_contains "session B shows its own, newer 25%" "$TH_OUT" "25% (X)"

run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_contains "session C (idle, no rate_limits yet) sees B's newer reading" "$TH_OUT" "25% (X)"

run_claude "$TH_TMP/payload-a.json" "$plain_dir"
assert_contains "session A re-renders (still its own stale 24% on stdin) but now shows B's 25% too" \
    "$TH_OUT" "25% (X)"

harness_summary
