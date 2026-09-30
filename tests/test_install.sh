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
assert_file_exists "lib deployed under ~/opt/agent-statusline" "$th_home/opt/agent-statusline/src/statusline/cache.sh"
assert_file_exists "Claude quota push script deployed as part of the shared lib" \
    "$th_home/opt/agent-statusline/src/statusline/push-claude-quota.sh"
assert_file_exists "Claude adapter deployed" "$th_home/.claude/statusline-command.sh"
diff -q "$REPO_ROOT/src/statusline/cache.sh" "$th_home/opt/agent-statusline/src/statusline/cache.sh" >/dev/null
assert_status "deployed lib matches the repo source" 0 $?

section "deploys the quota pollers and their LaunchAgent"
assert_file_exists "poll_claude.py deployed under ~/opt/agent-statusline/src/quota_polling" \
    "$th_home/opt/agent-statusline/src/quota_polling/poll_claude.py"
assert_file_exists "poll_codex.py deployed" "$th_home/opt/agent-statusline/src/quota_polling/poll_codex.py"
assert_file_exists "poll_all.py deployed" "$th_home/opt/agent-statusline/src/quota_polling/poll_all.py"
assert_file_exists "data/ created for the shared log" "$th_home/opt/agent-statusline/data"
assert_file_missing "adhoc_quotas_analysis/ is ad-hoc/dev-only, never deployed" \
    "$th_home/opt/agent-statusline/adhoc_quotas_analysis"
assert_file_exists "LaunchAgent plist written" \
    "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.plist"
assert_contains "plist points at src/quota_polling/poll_all.py" \
    "$(cat "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.plist")" "src/quota_polling/poll_all.py"
assert_eq "plist is symlinked into ~/Library/LaunchAgents, not copied" \
    "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.plist" \
    "$(readlink "$th_home/Library/LaunchAgents/com.jeanlescut.agent-statusline.plist")"
assert_file_exists "telemetry receiver deployed" "$th_home/opt/agent-statusline/src/telemetry/otlp_receiver.py"
assert_file_missing "the settings merge helper runs from the repo, never deployed" \
    "$th_home/opt/agent-statusline/src/telemetry/merge_claude_env.py"
assert_contains "receiver plist points at otlp_receiver.py" \
    "$(cat "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.otel.plist")" "src/telemetry/otlp_receiver.py"
assert_contains "receiver plist keeps it alive" \
    "$(cat "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.otel.plist")" "<key>KeepAlive</key>"
assert_eq "receiver plist is symlinked into ~/Library/LaunchAgents" \
    "$th_home/opt/agent-statusline/com.jeanlescut.agent-statusline.otel.plist" \
    "$(readlink "$th_home/Library/LaunchAgents/com.jeanlescut.agent-statusline.otel.plist")"
assert_eq "telemetry env vars merged into ~/.claude/settings.json" \
    "$(jq -cS . "$REPO_ROOT/src/telemetry/claude_telemetry_env.json")" "$(jq -cS .env "$th_home/.claude/settings.json")"

section "idempotent re-run: second run reports 'ok', not '[+]', for unchanged files"
run_install "$th_home"
assert_status "exits 0" 0 "$TH_STATUS"
assert_not_contains "no file gets re-installed on an unchanged re-run" "$TH_OUT" "[+]"
rm -rf "$th_home"

section "telemetry env merge leaves every other settings key alone"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-installhome.XXXXXX")"
mkdir -p "$th_home/.claude"
printf '{"theme":"dark","env":{"MY_VAR":"keep","OTEL_LOGS_EXPORTER":"console"}}\n' > "$th_home/.claude/settings.json"
run_install "$th_home"
assert_eq "other top-level keys untouched" "dark" "$(jq -r .theme "$th_home/.claude/settings.json")"
assert_eq "other env keys untouched" "keep" "$(jq -r .env.MY_VAR "$th_home/.claude/settings.json")"
assert_eq "an owned key is set to our value" "otlp" "$(jq -r .env.OTEL_LOGS_EXPORTER "$th_home/.claude/settings.json")"
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
