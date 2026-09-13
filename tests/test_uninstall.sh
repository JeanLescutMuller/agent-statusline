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
assert_file_missing "deployed quota research tooling removed" "$th_home/opt/agent-statusline/adhoc_quotas_analysis"
assert_file_missing "runtime state removed" "$th_home/opt/agent-statusline/state"
assert_file_missing "the whole runtime dir is gone when nothing was left to preserve (data/ was never populated)" \
    "$th_home/opt/agent-statusline"
assert_not_contains "no orphans reported on a clean install" "$TH_OUT" "orphan files/dirs under"
rm -rf "$th_home"

section "real quota data and the Codex patch build are preserved, not deleted"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-uninstallhome.XXXXXX")"
run_install "$th_home"
mkdir -p "$th_home/opt/agent-statusline/data" "$th_home/opt/agent-statusline/codex-patch/source-0.150.1"
printf '{"ts":1,"source":"claude_statusline"}\n' > "$th_home/opt/agent-statusline/data/claude-quota-history.jsonl"
printf 'build output\n' > "$th_home/opt/agent-statusline/codex-patch/build.log"
run_uninstall "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "reports preserving data/" "$TH_OUT" "preserved"
assert_file_exists "data/ survives" "$th_home/opt/agent-statusline/data/claude-quota-history.jsonl"
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

section "uninstalling an already-clean machine is a harmless no-op"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-uninstallhome.XXXXXX")"
run_uninstall "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
rm -rf "$th_home"

harness_summary
