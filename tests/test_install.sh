#!/bin/bash
# End-to-end tests for install.sh, run against a temp $HOME so nothing ever
# touches the real machine. `codex` is kept off PATH (actually exercising
# the Codex binary patch means a real network clone and Cargo build), except
# for a stub in the config-check section, where the patch step fails fast.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

INSTALL="$REPO_ROOT/install.sh"
CODEX_FREE_PATH="/opt/anaconda3/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin"

run_install() {
    local home="$1" err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    TH_OUT="$(HOME="$home" PATH="$CODEX_FREE_PATH" bash "$INSTALL" 2>"$err_file")"
    TH_STATUS=$?
    TH_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}

section "codex not on PATH: skips the Codex-specific steps cleanly"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-installhome.XXXXXX")"
run_install "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "reports skipping the patch step" "$TH_OUT" "Codex not installed"
assert_file_exists "the Codex adapter is still deployed unconditionally (ready for whenever Codex is installed)" \
    "$th_home/.codex/statusline-command.sh"
assert_file_missing "the Codex binary patch is not built/deployed" "$th_home/.codex/packages"
assert_file_missing "~/.codex/config.toml is not touched" "$th_home/.codex/config.toml"

section "deploys the shared lib and provider adapters"
assert_file_exists "lib deployed under ~/opt/agent-statusline" "$th_home/opt/agent-statusline/src/statusline/cache.sh"
assert_eq "Claude adapter is a symlink into the runtime copy, not a real file" \
    "$th_home/opt/agent-statusline/providers/claude-statusline-command.sh" "$(readlink "$th_home/.claude/statusline-command.sh")"
assert_eq "Codex adapter is a symlink too" \
    "$th_home/opt/agent-statusline/providers/codex-statusline-command.sh" "$(readlink "$th_home/.codex/statusline-command.sh")"
diff -q "$REPO_ROOT/providers/claude-statusline-command.sh" "$th_home/.claude/statusline-command.sh" >/dev/null
assert_status "the symlink resolves to the current provider" 0 $?
assert_file_missing "nothing of agent-usage-tracker's is deployed" "$th_home/opt/agent-usage-tracker"
assert_file_missing "no LaunchAgent at all" "$th_home/Library/LaunchAgents"
assert_file_missing "~/.claude/settings.json is not touched" "$th_home/.claude/settings.json"
diff -q "$REPO_ROOT/src/statusline/cache.sh" "$th_home/opt/agent-statusline/src/statusline/cache.sh" >/dev/null
assert_status "deployed lib matches the repo source" 0 $?

section "idempotent re-run: second run reports 'ok', not '[+]', for unchanged files"
run_install "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_not_contains "no file gets re-installed on an unchanged re-run" "$TH_OUT" "[+]"
rm -rf "$th_home"

section "a stale real file at the adapter path is replaced by the symlink"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-installhome.XXXXXX")"
mkdir -p "$th_home/.claude"
printf 'stale copy\n' > "$th_home/.claude/statusline-command.sh"
run_install "$th_home"
assert_eq "now a symlink" "$th_home/opt/agent-statusline/providers/claude-statusline-command.sh" \
    "$(readlink "$th_home/.claude/statusline-command.sh")"
rm -rf "$th_home"

section "Codex [tui] config is checked, never edited"
stub_bin="$(mktemp -d "${TMPDIR:-/tmp}/th-codexstub.XXXXXX")"
printf '#!/bin/sh\nexit 0\n' > "$stub_bin/codex"; chmod +x "$stub_bin/codex"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-installhome.XXXXXX")"
TH_OUT="$(HOME="$th_home" PATH="$stub_bin:$CODEX_FREE_PATH" bash "$INSTALL" 2>/dev/null)"
assert_contains "no config.toml: prints the keys to add" "$TH_OUT" 'status_line = ["custom"]'
assert_file_missing "...and does not create the file" "$th_home/.codex/config.toml"
printf '[tui]\nstatus_line = ["custom"]\nstatus_line_use_colors = true\n' > "$th_home/.codex/config.toml"
before="$(cat "$th_home/.codex/config.toml")"
TH_OUT="$(HOME="$th_home" PATH="$stub_bin:$CODEX_FREE_PATH" bash "$INSTALL" 2>/dev/null)"
assert_not_contains "configured: nothing to add" "$TH_OUT" "add to"
assert_eq "config.toml left byte-identical" "$before" "$(cat "$th_home/.codex/config.toml")"
rm -rf "$th_home" "$stub_bin"

harness_summary
