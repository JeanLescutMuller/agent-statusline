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

section "rate_limits without a five_hour window: 0%, not a dash or an old value"
# The API reports utilization 0 / resets_at null when no 5h window is open,
# and stdin then omits five_hour.
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime-nowindow.XXXXXX")"
jq '. + {rate_limits: {seven_day: {used_percentage: 16, resets_at: 1788307200}}}' \
    "$FIXTURES/claude-payload.json" > "$TH_TMP/payload-nowin.json"
run_claude "$TH_TMP/payload-nowin.json" "$plain_dir"
assert_contains "5h shows 0%" "$TH_OUT" "5h"
assert_match "5h is 0%" "$(printf '%s\n' "$TH_OUT" | sed -n 3p)" '5h.*\] .*0%'
assert_contains "7d from stdin" "$TH_OUT" "16%"

section "agent-usage-tracker absent: each session shows its own reading"
STATUSLINE_RUNTIME_DIR="$(mktemp -d "$TH_TMP/runtime-solo.XXXXXX")"
payload_for() {
    jq --argjson p "$1" '. + {rate_limits: (.rate_limits + {five_hour: {used_percentage: $p, resets_at: 1788091200}})}' \
        "$FIXTURES/claude-payload.json" > "$2"
}
payload_for 24 "$TH_TMP/payload-a.json"
payload_for 25 "$TH_TMP/payload-b.json"
run_claude "$TH_TMP/payload-a.json" "$plain_dir"
assert_contains "session A shows its own 24%" "$TH_OUT" "24%"
run_claude "$TH_TMP/payload-b.json" "$plain_dir"
assert_contains "session B shows its own 25%" "$TH_OUT" "25%"
run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_match "session C (no reading) shows a dash" "$(printf '%s\n' "$TH_OUT" | sed -n 3p)" '5h.*–'
assert_file_missing "nothing is created under the tracker's directory" "$AGENT_USAGE_TRACKER_DIR"
assert_file_missing "no quota file of our own" "$STATUSLINE_RUNTIME_DIR/state/quota"
assert_file_exists "every render touches the liveness heartbeat the tracker's pollers read" \
    "$STATUSLINE_RUNTIME_DIR/state/heartbeat/claude"

# A stub tracker: its reader saves exactly what it received, and prints a
# line the way the real one does (the FS-separated format).
SEP=$'\034'
STUB_READER=src/statusline_payload_reader.py
stub_tracker() {
    local dir="$1" line="$2"
    mkdir -p "$dir/src"
    cat > "$dir/$STUB_READER" <<STUB
#!/bin/bash
cat > "$dir/received.json"
printf '%s\n' "$line"
STUB
    chmod +x "$dir/$STUB_READER"
}

section "agent-usage-tracker present: the raw payload goes in, its printed reading is shown"
AGENT_USAGE_TRACKER_DIR="$TH_TMP/tracker"
stub_tracker "$AGENT_USAGE_TRACKER_DIR" "61${SEP}1788091200${SEP}72${SEP}1788307200${SEP}statusline${SEP}1767229200"
run_claude "$TH_TMP/payload-a.json" "$plain_dir"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "the reader receives the stdin payload unchanged (bar the trailing newline)" \
    "$(sed "s#__CWD__#$plain_dir#" "$TH_TMP/payload-a.json")" "$(cat "$AGENT_USAGE_TRACKER_DIR/received.json")"
assert_contains "5h comes from the tracker's line, whatever its source" "$TH_OUT" "61%"
assert_contains "7d too" "$TH_OUT" "72%"
assert_not_contains "not this session's own 24%" "$TH_OUT" "24%"
rm -f "$AGENT_USAGE_TRACKER_DIR/received.json"
run_claude "$FIXTURES/claude-payload-minimal.json" "$plain_dir"
assert_file_exists "a payload without rate_limits is forwarded too - the tracker decides" \
    "$AGENT_USAGE_TRACKER_DIR/received.json"
assert_contains "a render with no rate_limits shows the tracker's reading" "$TH_OUT" "61%"

section "a tracker line without a 5h percent falls back to this session's reading"
stub_tracker "$AGENT_USAGE_TRACKER_DIR" "${SEP}${SEP}${SEP}${SEP}API${SEP}1767229200"
run_claude "$TH_TMP/payload-b.json" "$plain_dir"
assert_contains "this session's 25% is shown" "$TH_OUT" "25%"

section "a reader printing nothing falls back to this session's reading"
stub_tracker "$AGENT_USAGE_TRACKER_DIR" ""
run_claude "$TH_TMP/payload-b.json" "$plain_dir"
assert_contains "this session's 25% is shown" "$TH_OUT" "25%"

section "a failing reader never breaks the render"
cat > "$AGENT_USAGE_TRACKER_DIR/$STUB_READER" <<'STUB'
#!/bin/bash
echo "5h 99%"
echo "boom" >&2
exit 3
STUB
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
assert_status "exits 0" 0 "$TH_STATUS"
assert_eq "still three lines" "3" "$(printf '%s\n' "$TH_OUT" | wc -l | tr -d ' ')"
assert_not_contains "its stderr doesn't leak" "$TH_ERR" "boom"
assert_not_contains "nor its output, when it failed" "$TH_OUT" "99%"

section "a non-executable reader is not run"
rm -f "$AGENT_USAGE_TRACKER_DIR/received.json"
printf '#!/bin/bash\ncat > "%s/received.json"\n' "$AGENT_USAGE_TRACKER_DIR" > "$AGENT_USAGE_TRACKER_DIR/$STUB_READER"
chmod -x "$AGENT_USAGE_TRACKER_DIR/$STUB_READER"
run_claude "$FIXTURES/claude-payload.json" "$plain_dir"
assert_file_missing "nothing received" "$AGENT_USAGE_TRACKER_DIR/received.json"

harness_summary
