#!/bin/bash
# End-to-end tests for install.sh, run against a temp $HOME so nothing ever
# touches the real machine. `codex` is deliberately kept off PATH here (a
# restricted PATH that excludes ~/.local/bin, where it's really installed) -
# actually exercising the Codex binary patch would mean a real network clone
# and Cargo build, which does not belong in this test suite. The TOML-merge
# logic that install.sh's Codex-config step drives is instead exercised
# directly below, by extracting the real heredoc rather than retyping it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

INSTALL="$REPO_ROOT/install.sh"
CODEX_FREE_PATH="/opt/anaconda3/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin"

run_install() {
    local home="$1" err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/th-err.XXXXXX")"
    # AGENT_STATUSLINE_SKIP_LAUNCHD: gui/$(id -u) is a real per-user launchd
    # domain a HOME override can't sandbox - without this, every test run
    # would bootstrap a real LaunchAgent pointing at a temp dir that's
    # deleted when the test ends.
    TH_OUT="$(HOME="$home" PATH="$CODEX_FREE_PATH" AGENT_STATUSLINE_SKIP_LAUNCHD=1 \
        bash "$INSTALL" 2>"$err_file")"
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
assert_file_exists "lib deployed under ~/opt/agent-statusline" "$th_home/opt/agent-statusline/lib/statusline-cache.sh"
assert_file_exists "Claude quota refresh script deployed as part of the shared lib" \
    "$th_home/opt/agent-statusline/lib/statusline-refresh-claude-quota.sh"
assert_file_exists "Claude adapter deployed" "$th_home/.claude/statusline-command.sh"
diff -q "$REPO_ROOT/lib/statusline-cache.sh" "$th_home/opt/agent-statusline/lib/statusline-cache.sh" >/dev/null
assert_status "deployed lib matches the repo source" 0 $?

section "deploys the quota pollers and their LaunchAgent"
assert_file_exists "poll_claude.py deployed under ~/opt/agent-statusline/quota" \
    "$th_home/opt/agent-statusline/quota/poll_claude.py"
assert_file_exists "poll_codex.py deployed" "$th_home/opt/agent-statusline/quota/poll_codex.py"
assert_file_exists "poll_all.py deployed" "$th_home/opt/agent-statusline/quota/poll_all.py"
assert_file_exists "data/ created for the shared log" "$th_home/opt/agent-statusline/data"
assert_file_exists "LaunchAgent plist written" \
    "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.plist"
assert_contains "plist points at quota/poll_all.py" \
    "$(cat "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.plist")" "quota/poll_all.py"
assert_eq "plist is symlinked into ~/Library/LaunchAgents, not copied" \
    "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.plist" \
    "$(readlink "$th_home/Library/LaunchAgents/com.jeanlescut.agent-statusline.plist")"

section "idempotent re-run: second run reports 'ok', not '[+]', for unchanged files"
run_install "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_not_contains "no file gets re-installed on an unchanged re-run" "$TH_OUT" "[+]"
rm -rf "$th_home"

section "legacy runtime migration"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-installhome.XXXXXX")"
legacy="$th_home/opt/bootstrap-home/statusline"
mkdir -p "$legacy/state/static" "$legacy/locks" "$legacy/logs"
printf 'legacy-host\n' > "$legacy/state/static/hostname"
printf 'legacy-log\n' > "$legacy/logs/statusline.log"
run_install "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "reports the migration" "$TH_OUT" "migrated runtime state"
assert_file_exists "state moved to the new runtime dir" "$th_home/opt/agent-statusline/state/static/hostname"
assert_eq "migrated content is preserved, not regenerated" "legacy-host" "$(cat "$th_home/opt/agent-statusline/state/static/hostname")"
assert_file_exists "logs moved to the new runtime dir" "$th_home/opt/agent-statusline/logs/statusline.log"
assert_file_missing "the legacy runtime dir is gone" "$legacy"
rm -rf "$th_home"

section "migrates agent-quota-tracker's live deployment"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-installhome.XXXXXX")"
old_folder="$th_home/opt/agent-quota-tracker"
mkdir -p "$old_folder/data" "$th_home/Library/LaunchAgents"
printf '{"ts":1,"source":"claude","api":{}}\n' > "$old_folder/data/utilization-log.jsonl"
printf 'fake plist\n' > "$th_home/Library/LaunchAgents/com.jeanlescut.agent-quota-tracker.plist"
run_install "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "reports the migration" "$TH_OUT" "migrated from ~/opt/agent-quota-tracker"
assert_file_missing "the old deployed folder is gone" "$old_folder"
assert_file_missing "the old LaunchAgent symlink is removed" \
    "$th_home/Library/LaunchAgents/com.jeanlescut.agent-quota-tracker.plist"
assert_file_exists "its data/ is carried forward" \
    "$th_home/opt/agent-statusline/data/utilization-log.jsonl"
assert_contains "carried-forward content is preserved, not regenerated" \
    "$(cat "$th_home/opt/agent-statusline/data/utilization-log.jsonl")" '"ts":1'
run_install "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_not_contains "no migration message on a second run - old folder is already gone" \
    "$TH_OUT" "migrated from ~/opt/agent-quota-tracker"
rm -rf "$th_home"

section "orphaned pre-2026-08-30 usage-fetch helper is removed"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-installhome.XXXXXX")"
mkdir -p "$th_home/.claude"
printf 'stale\n' > "$th_home/.claude/statusline-usage-fetch.sh"
run_install "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_file_missing "the orphaned helper is cleaned up, replaced by the shared lib's refresh script" \
    "$th_home/.claude/statusline-usage-fetch.sh"
rm -rf "$th_home"

section "Codex [tui] config merge (the real heredoc, extracted, not retyped)"
merge_script="$(mktemp "${TMPDIR:-/tmp}/th-merge.XXXXXX.py")"
awk '/<<.PY.$/{flag=1; next} /^PY$/{flag=0} flag' "$INSTALL" > "$merge_script"
assert_file_exists "extracted the merge script from install.sh" "$merge_script"
[ -s "$merge_script" ]
assert_status "extracted script is non-empty" 0 $?

merge_dir="$(mktemp -d "${TMPDIR:-/tmp}/th-mergecfg.XXXXXX")"

section "  no existing config.toml"
config="$merge_dir/none/config.toml"
CODEX_CONFIG="$config" CODEX_DESIRED="$REPO_ROOT/codex-patch/codex_tui.toml" python3 "$merge_script" >/dev/null
assert_file_exists "creates config.toml with a [tui] table" "$config"
assert_contains "sets status_line_command" "$(cat "$config")" "status_line_command"

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
assert_contains "adds the status line keys" "$(cat "$config")" "status_line_command"
python3 -c "import tomllib,sys; tomllib.load(open('$config','rb'))"
assert_status "result is still valid TOML" 0 $?

section "  stale status_line_command table is replaced, not duplicated"
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
assert_eq "exactly one [tui.status_line_command] table after the merge" "1" "$occurrences"
assert_not_contains "the stale command path is gone" "$(cat "$config")" "/old/stale/path.sh"
python3 -c "import tomllib,sys; tomllib.load(open('$config','rb'))"
assert_status "result is still valid TOML" 0 $?

rm -rf "$merge_dir" "$merge_script"

harness_summary
