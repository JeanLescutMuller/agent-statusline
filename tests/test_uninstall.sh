#!/bin/bash
# End-to-end tests for uninstall.sh, run against a temp $HOME so nothing ever
# touches the real machine. Covers: full removal of what install.sh deploys,
# data/ and codex-patch/ preserved rather than blindly deleted, and an
# unrecognized leftover file/dir is reported as an orphan instead of being
# silently removed or silently ignored.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

INSTALL="$REPO_ROOT/install.sh"
UNINSTALL="$REPO_ROOT/uninstall.sh"
CODEX_FREE_PATH="/opt/anaconda3/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin"

run_install() {
    local home="$1"
    HOME="$home" PATH="$CODEX_FREE_PATH" AGENT_STATUSLINE_SKIP_LAUNCHD=1 bash "$INSTALL" >/dev/null 2>&1
}

run_uninstall() {
    local home="$1" err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    TH_OUT="$(HOME="$home" AGENT_STATUSLINE_SKIP_LAUNCHD=1 bash "$UNINSTALL" 2>"$err_file")"
    TH_STATUS=$?
    TH_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}

section "uninstalling a fresh install removes everything it deployed"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-uninstallhome.XXXXXX")"
run_install "$th_home"
run_uninstall "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "LaunchAgent symlink removed" \
    "$th_home/Library/LaunchAgents/com.jeanlescut.agent-statusline.plist"
assert_file_missing "Claude provider adapter removed" "$th_home/.claude/statusline-command.sh"
assert_file_missing "Codex provider adapter removed" "$th_home/.codex/statusline-command.sh"
assert_file_missing "deployed shared lib removed" "$th_home/opt/agent-statusline/src"
assert_file_missing "runtime state removed" "$th_home/opt/agent-statusline/state"
assert_file_missing "the whole runtime dir is gone when nothing was left to preserve (data/ was never populated)" \
    "$th_home/opt/agent-statusline"
assert_not_contains "no orphans reported on a clean install" "$TH_OUT" "orphan files/dirs under"
rm -rf "$th_home"

section "telemetry: LaunchAgent removed, only our env keys removed from settings.json"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-uninstallhome.XXXXXX")"
mkdir -p "$th_home/.claude"
printf '{"theme":"dark","env":{"MY_VAR":"keep"}}\n' > "$th_home/.claude/settings.json"
run_install "$th_home"
# A value changed by hand after install is someone else's now - must survive.
jq '.env.OTEL_EXPORTER_OTLP_ENDPOINT = "http://elsewhere:4318"' "$th_home/.claude/settings.json" > "$th_home/s.tmp" \
    && mv "$th_home/s.tmp" "$th_home/.claude/settings.json"
run_uninstall "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "receiver LaunchAgent symlink removed" \
    "$th_home/Library/LaunchAgents/com.jeanlescut.agent-statusline.otel.plist"
assert_eq "our unchanged env keys removed, hand-changed and foreign ones kept" \
    '{"MY_VAR":"keep","OTEL_EXPORTER_OTLP_ENDPOINT":"http://elsewhere:4318"}' \
    "$(jq -cS .env "$th_home/.claude/settings.json")"
assert_eq "other top-level keys untouched" "dark" "$(jq -r .theme "$th_home/.claude/settings.json")"
rm -rf "$th_home"

section "real quota data and the Codex patch build are preserved, not deleted"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-uninstallhome.XXXXXX")"
run_install "$th_home"
mkdir -p "$th_home/opt/agent-statusline/data" "$th_home/opt/agent-statusline/codex-patch/source-0.150.1"
printf '{"ts":1,"source":"claude_statusline"}\n' > "$th_home/opt/agent-statusline/data/claude/account.jsonl"
printf 'build output\n' > "$th_home/opt/agent-statusline/codex-patch/build.log"
run_uninstall "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "reports preserving data/" "$TH_OUT" "preserved"
assert_file_exists "data/ survives" "$th_home/opt/agent-statusline/data/claude/account.jsonl"
assert_file_exists "codex-patch/ build artifacts survive" "$th_home/opt/agent-statusline/codex-patch/build.log"
assert_file_missing "deployed code is still gone" "$th_home/opt/agent-statusline/src"
assert_not_contains "data/ and codex-patch/ are not reported as orphans" "$TH_OUT" "mystery"
rm -rf "$th_home"

section "an unrecognized leftover is flagged as an orphan, not silently removed"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-uninstallhome.XXXXXX")"
run_install "$th_home"
mkdir -p "$th_home/opt/agent-statusline/mystery-dir"
printf 'unexplained\n' > "$th_home/opt/agent-statusline/mystery-dir/file.txt"
run_uninstall "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "reports the orphan" "$TH_OUT" "orphan files/dirs under"
assert_contains "names the orphaned path" "$TH_OUT" "mystery-dir"
assert_file_exists "the orphan itself is left untouched" "$th_home/opt/agent-statusline/mystery-dir/file.txt"
rm -rf "$th_home"

section "a known target that can't be fully cleared is reported distinctly, not as an unrecognized orphan"
# Simulates what a concurrently-rendering session's own writes into state/
# look like to uninstall.sh: a directory whose contents keep resisting
# removal. A permission-based block (parent dir not writable) reproduces the
# same "still non-empty after rm -rf" outcome as a real concurrent writer,
# deterministically instead of racing a timer.
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-uninstallhome.XXXXXX")"
run_install "$th_home"
stuck_dir="$th_home/opt/agent-statusline/state/git/cwd/stuck"
mkdir -p "$stuck_dir"
printf 'x\n' > "$stuck_dir/local.attempted"
chmod 555 "$stuck_dir"
run_uninstall "$th_home"
chmod 755 "$stuck_dir"
assert_status "exits 0 even when a known target can't be fully cleared" 0 "$TH_STATUS"
assert_contains "explains it couldn't fully remove state - likely another session" \
    "$TH_OUT" "couldn't fully remove"
assert_contains "names the stuck target" "$TH_OUT" "state"
assert_not_contains "does not ALSO get reported as an unrecognized orphan" \
    "$TH_OUT" "orphan files/dirs under"
rm -rf "$th_home"

section "uninstalling an already-clean machine is a harmless no-op"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-uninstallhome.XXXXXX")"
run_uninstall "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
rm -rf "$th_home"

harness_summary
