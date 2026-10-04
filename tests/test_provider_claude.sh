#!/bin/bash
# End-to-end tests for providers/claude-statusline-command.sh, following the
# README's "Offline testing" recipe: STATUSLINE_RUNTIME_DIR/STATUSLINE_LIB_DIR
# point at an isolated temp runtime, and a captured payload is piped in.
#
# HOME is also overridden per call: statusline_read_static falls back to
# $HOME/opt/bootstrap-home/bin/get_host_color - pointing HOME at an empty
# temp dir makes that miss deterministic instead of quietly depending on
# what's installed on the machine running the suite.
#
# agent-usage-tracker is never the real one: AGENT_USAGE_TRACKER_DIR points
# at an empty temp dir (tracker absent) or at a stub that records what it
# was sent - this suite tests this repo's side of the contract only.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

PROVIDER="$REPO_ROOT/providers/claude-statusline-command.sh"
FIXTURES="$TESTS_DIR/fixtures"

th_tmp_runtime
TH_HOME="$(mktemp -d "$TH_TMP/home.XXXXXX")"
TH_HOME="$(cd "$TH_HOME" && pwd -P)"
export AGENT_USAGE_TRACKER_DIR="$TH_TMP/no-tracker"

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
assert_contains "5h shows this render's own reading, via the own cache" "$TH_OUT" "55%"

section "full payload outside a git repo"
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
assert_not_contains "no git segment when cwd isn't a repo" "$TH_OUT" "🌿"
assert_contains "cwd is still shown and collapsed" "$TH_OUT" "~/plain"

section "minimal payload (nulls/missing fields), nothing cached anywhere"
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime-min.XXXXXX")"
run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "model defaults to Claude" "$TH_OUT" "🤖 Claude"
assert_contains "context defaults to 0%" "$TH_OUT" "0%"
line3="$(printf '%s\n' "$TH_OUT" | sed -n 3p)"
assert_match "no quota reading anywhere: 5h shows a dash" "$line3" '5h.*–'
assert_match "...and 7d too" "$line3" '7d.*–'
assert_eq "...never a made-up 0% (only the context segment has a %)" "1" "$(printf '%s' "$line3" | grep -o '%' | wc -l | tr -d ' ')"
assert_file_missing "no reading, so no own cache file written" "$STATUSLINE_RUNTIME_DIR/state/quota/claude"

section "rate_limits without a five_hour window: 0%, not a dash or an old value"
# The API reports utilization 0 / resets_at null when no 5h window is open,
# and stdin then omits five_hour.
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime-nowindow.XXXXXX")"
printf '{"type":"assistant","timestamp":"2026-01-02T00:00:00Z"}\n' > "$TH_TMP/t-nowin.jsonl"
jq --arg t "$TH_TMP/t-nowin.jsonl" '. + {transcript_path: $t, rate_limits: {seven_day: {used_percentage: 16, resets_at: 1788307200}}}' \
    "$FIXTURES/claude-payload.json" > "$TH_TMP/payload-nowin.json"
run_claude "$TH_TMP/payload-nowin.json" "$plain_dir"
assert_contains "5h shows 0%" "$TH_OUT" "5h"
assert_match "5h is 0%" "$(printf '%s\n' "$TH_OUT" | sed -n 3p)" '5h.*\] .*0%'
assert_contains "7d from stdin" "$TH_OUT" "16%"

section "agent-usage-tracker absent: the own cache still makes sessions converge"
# Three "sessions" with their own stdin readings: A's last message was
# earliest, B's later, C hasn't sent one. Whichever reading is freshest
# (transcript timestamp) is shown by all of them.
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime-conv.XXXXXX")"
payload_for() {
    local pct="$1" ts="$2" out="$3" transcript
    transcript="$TH_TMP/transcript-$pct.jsonl"
    printf '{"type":"assistant","timestamp":"%s"}\n' "$ts" > "$transcript"
    jq --arg t "$transcript" --argjson p "$pct" \
        '. + {transcript_path: $t, rate_limits: (.rate_limits + {five_hour: {used_percentage: $p, resets_at: 1788091200}})}' \
        "$FIXTURES/claude-payload.json" > "$out"
}
payload_for 24 "2026-01-01T00:00:00.000Z" "$TH_TMP/payload-a.json"
payload_for 25 "2026-01-01T00:05:00.000Z" "$TH_TMP/payload-b.json"
run_claude "$TH_TMP/payload-a.json" "$plain_dir"
assert_contains "session A shows its own 24%" "$TH_OUT" "24%"
run_claude "$TH_TMP/payload-b.json" "$plain_dir"
assert_contains "session B shows its own, newer 25%" "$TH_OUT" "25%"
run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_contains "session C (no message yet) shows B's reading, not a dash" "$TH_OUT" "25%"
run_claude "$TH_TMP/payload-a.json" "$plain_dir"
assert_contains "session A re-renders its stale 24% but shows B's 25%" "$TH_OUT" "25%"
assert_file_missing "nothing is created under the tracker's directory" "$AGENT_USAGE_TRACKER_DIR"
assert_file_exists "every render touches the liveness heartbeat the tracker's pollers read" \
    "$STATUSLINE_RUNTIME_DIR/state/heartbeat/claude"

# A stub tracker: its ingest script saves exactly what it received, and
# writes a state file the way the real one does (the FS-separated format).
SEP=$'\034'
stub_tracker() {
    local dir="$1" state_line="$2"
    mkdir -p "$dir/bin" "$dir/state/quota"
    cat > "$dir/bin/ingest-claude-statusline.sh" <<STUB
#!/bin/bash
cat > "$dir/received.json"
printf '%s\n' "$state_line" > "$dir/state/quota/claude"
STUB
    chmod +x "$dir/bin/ingest-claude-statusline.sh"
}

section "an idle session's frozen reading never beats a fresher one"
# Regression (2026-10-01): a session idle for days keeps sending its old
# reading while its transcript gains entries without an assistant message;
# it used to be stamped "now" and froze every statusline on it.
printf '%s\n' '{"type":"assistant","timestamp":"2025-12-30T00:00:00Z"}' \
    '{"type":"attachment","timestamp":"2026-01-05T00:00:00Z"}' '{"type":"ai-title"}' > "$TH_TMP/t-idle.jsonl"
jq --arg t "$TH_TMP/t-idle.jsonl" '. + {transcript_path: $t, rate_limits: {seven_day: {used_percentage: 11, resets_at: 1788307200}}}' \
    "$FIXTURES/claude-payload.json" > "$TH_TMP/payload-idle.json"
run_claude "$TH_TMP/payload-idle.json" "$plain_dir"
assert_contains "the idle session shows B's fresher reading" "$TH_OUT" "25%"
assert_not_contains "...not its own frozen 11%" "$TH_OUT" "11%"
printf '%s\n' '{"type":"ai-title"}' '{"type":"mode"}' > "$TH_TMP/t-idle.jsonl"
run_claude "$TH_TMP/payload-idle.json" "$plain_dir"
assert_contains "no assistant message at all: still B's reading (unknown age never wins)" "$TH_OUT" "25%"

section "agent-usage-tracker present: the raw payload goes in, a fresher tracker reading wins"
# A's own reading is from 2026-01-01T00:00Z (1767225600); the tracker's
# poll is later.
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime-tracker.XXXXXX")"
AGENT_USAGE_TRACKER_DIR="$TH_TMP/tracker"
stub_tracker "$AGENT_USAGE_TRACKER_DIR" "61${SEP}1788091200${SEP}72${SEP}1788307200${SEP}P${SEP}1767229200"
run_claude "$TH_TMP/payload-a.json" "$plain_dir"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "the ingest script receives the stdin payload unchanged (bar the trailing newline)" \
    "$(sed "s#__CWD__#$plain_dir#" "$TH_TMP/payload-a.json")" "$(cat "$AGENT_USAGE_TRACKER_DIR/received.json")"
assert_contains "5h comes from the tracker's newer reading, " "$TH_OUT" "61%"
assert_contains "7d too" "$TH_OUT" "72%"
rm -f "$AGENT_USAGE_TRACKER_DIR/received.json"
run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_file_exists "a payload without rate_limits is forwarded too - the tracker decides" \
    "$AGENT_USAGE_TRACKER_DIR/received.json"
assert_contains "a render with no rate_limits shows the freshest reading" "$TH_OUT" "61%"

section "a stale tracker file never freezes the display (e.g. a broken ingest script)"
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime-stale.XXXXXX")"
stub_tracker "$AGENT_USAGE_TRACKER_DIR" "99${SEP}${SEP}99${SEP}${SEP}P${SEP}1000"
run_claude "$TH_TMP/payload-b.json" "$plain_dir"
assert_contains "this render's newer own reading is shown" "$TH_OUT" "25%"
assert_not_contains "the stale 99% is not" "$TH_OUT" "99%"

section "the tracker's X readings are ignored, however fresh they claim to be"
# Regression (2026-10-02): the tracker stamped an idle session's frozen
# reading "now", and the display flapped to it.
stub_tracker "$AGENT_USAGE_TRACKER_DIR" "0${SEP}${SEP}11${SEP}${SEP}X${SEP}9999999999"
run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_contains "the own cache's reading is shown" "$TH_OUT" "25%"
assert_not_contains "not the tracker's X reading" "$TH_OUT" "11%"

section "a failing ingest script never breaks the render"
cat > "$AGENT_USAGE_TRACKER_DIR/bin/ingest-claude-statusline.sh" <<'STUB'
#!/bin/bash
echo "boom" >&2
exit 3
STUB
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "still three lines" "3" "$(printf '%s\n' "$TH_OUT" | wc -l | tr -d ' ')"
assert_not_contains "its stderr doesn't leak" "$TH_ERR" "boom"

section "a non-executable ingest script is not run"
rm -f "$AGENT_USAGE_TRACKER_DIR/received.json"
printf '#!/bin/bash\ncat > "%s/received.json"\n' "$AGENT_USAGE_TRACKER_DIR" > "$AGENT_USAGE_TRACKER_DIR/bin/ingest-claude-statusline.sh"
chmod -x "$AGENT_USAGE_TRACKER_DIR/bin/ingest-claude-statusline.sh"
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
assert_file_missing "nothing received" "$AGENT_USAGE_TRACKER_DIR/received.json"

harness_summary
