#!/bin/bash
# End-to-end tests for install.sh, run against a temp $HOME so nothing ever
# touches the real machine. `codex` is deliberately kept off PATH here (a
# restricted PATH that excludes ~/.local/bin, where it's really installed) -
# actually exercising the Codex binary patch would mean a real network clone
# and Cargo build, which does not belong in this test suite. The TOML-merge
# logic that install.sh's Codex-config step drives lives in its own file,
# codex-patch/merge_codex_config.py, exercised directly below.
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
assert_file_missing "no data/ - usage history belongs to agent-usage-tracker" "$th_home/opt/agent-statusline/data"
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

section "Codex [tui] config merge"
merge_script="$REPO_ROOT/codex-patch/merge_codex_config.py"

merge_dir="$(mktemp -d "${TMPDIR:-/tmp}/th-mergecfg.XXXXXX")"

section "  no existing config.toml"
config="$merge_dir/none/config.toml"
CODEX_CONFIG="$config" CODEX_DESIRED="$REPO_ROOT/codex-patch/codex_tui.toml" python3 "$merge_script" >/dev/null
assert_file_exists "creates config.toml with a [tui] table" "$config"
assert_contains "selects the custom status-line item" "$(cat "$config")" 'status_line = ["custom"]'
assert_not_contains "does not write the obsolete command table" "$(cat "$config")" "status_line_command"

section "  existing [tui] table with unrelated keys is preserved"
config="$merge_dir/unrelated/config.toml"
mkdir -p "$(dirname "$config")"
cat > "$config" <<'EOF'
[tui]
some_unrelated_key = true

[other_table]
x = 1
EOF
CODEX_CONFIG="$config" CODEX_DESIRED="$REPO_ROOT/codex-patch/codex_tui.toml" python3 "$merge_script" >/dev/null
assert_contains "keeps the unrelated [tui] key" "$(cat "$config")" "some_unrelated_key = true"
assert_contains "keeps the unrelated table entirely" "$(cat "$config")" "[other_table]"
assert_contains "adds the status line keys" "$(cat "$config")" 'status_line = ["custom"]'
python3 -c "import tomllib,sys; tomllib.load(open('$config','rb'))"
assert_status "result is still valid TOML" 0 $?

section "  stale status_line_command table is removed"
config="$merge_dir/stale/config.toml"
mkdir -p "$(dirname "$config")"
cat > "$config" <<'EOF'
[tui]
status_line = ["custom"]
status_line_use_colors = true

[tui.status_line_command]
command = ["bash", "/old/stale/path.sh"]
refresh_interval = 99
EOF
CODEX_CONFIG="$config" CODEX_DESIRED="$REPO_ROOT/codex-patch/codex_tui.toml" python3 "$merge_script" >/dev/null
occurrences="$(grep -c 'status_line_command' "$config")"
assert_eq "no dead [tui.status_line_command] table remains after the merge" "0" "$occurrences"
assert_not_contains "the stale command path is gone" "$(cat "$config")" "/old/stale/path.sh"
python3 -c "import tomllib,sys; tomllib.load(open('$config','rb'))"
assert_status "result is still valid TOML" 0 $?

rm -rf "$merge_dir"

harness_summary
