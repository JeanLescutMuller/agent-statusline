#!/bin/bash
# Idempotent installer for agent-statusline, for a machine with no prior
# agent-statusline (or predecessor-project) install. Carries no one-time
# migration logic on purpose: if you're moving between incompatible on-disk
# layouts (this repo's own history has had several), run uninstall.sh first
# - it removes everything this script deploys, preserves data/ (irreplaceable
# quota history), and flags anything left over as an orphan to check by
# hand - then re-run this script against a clean machine. A bare
# install/uninstall pair is easier to keep correct forever than an
# ever-growing pile of one-off legacy-layout guards in this file.
#
# Deploys the shared cache/format library and the Claude/Codex provider
# adapters, deploys the quota-tracking research tooling (folded in from the
# former agent-quota-tracker repo - see adhoc_quotas_analysis/AGENTS.md) and
# the scheduled pollers under src/quota_polling/ plus their LaunchAgent, and -
# when Codex is installed - builds/deploys the status-line-command patch and
# wires ~/.codex/config.toml's [tui] status-line keys.
#
# Depends on bootstrap-home's ~/opt/bootstrap-home/bin/get_host_color being on
# disk (used by the cache library for a deterministic per-host color); its
# absence just falls back to a default color, it is not a hard dependency.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH"; exit 1; }
PYTHON3="$(command -v python3)"

RUNTIME="$HOME/opt/agent-statusline"
LIB_DIR="$RUNTIME/src/statusline"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} agent-statusline install${NC}"
echo -e "${GREEN}========================================${NC}"

_backup_before_overwrite() {
    local target="$1"
    [ -f "$target" ] && cp "$target" "${target}.bak"
}

_deploy() {
    local src="$1" target="$2"
    mkdir -p "$(dirname "$target")"
    if [ -f "$target" ] && diff -q "$src" "$target" >/dev/null 2>&1; then
        ok "$(basename "$target")"
        return
    fi
    _backup_before_overwrite "$target"
    cp "$src" "$target"
    chmod +x "$target" 2>/dev/null || true
    installed "$(basename "$target")"
}

step "shared cache library"
mkdir -p "$LIB_DIR"
for f in "$SCRIPT_DIR"/src/statusline/*.sh; do
    _deploy "$f" "$LIB_DIR/$(basename "$f")"
done

step "provider adapters"
_deploy "$SCRIPT_DIR/providers/claude-statusline-command.sh" "$HOME/.claude/statusline-command.sh"
_deploy "$SCRIPT_DIR/providers/codex-statusline-command.sh" "$HOME/.codex/statusline-command.sh"

step "runtime state"
mkdir -p "$RUNTIME/state/static" "$RUNTIME/locks" "$RUNTIME/logs"
ok "runtime state"

step "quota tracker"
mkdir -p "$RUNTIME/adhoc_quotas_analysis" "$RUNTIME/data"
for f in "$SCRIPT_DIR"/adhoc_quotas_analysis/*.py; do
    _deploy "$f" "$RUNTIME/adhoc_quotas_analysis/$(basename "$f")"
done

step "quota polling"
mkdir -p "$RUNTIME/src/quota_polling"
for f in "$SCRIPT_DIR"/src/quota_polling/*.py; do
    _deploy "$f" "$RUNTIME/src/quota_polling/$(basename "$f")"
done

QUOTA_LABEL="com.jeanlescut.agent-statusline"
QUOTA_REAL_PLIST="$RUNTIME/$QUOTA_LABEL.plist"
QUOTA_LINK_PLIST="$LAUNCH_AGENTS/$QUOTA_LABEL.plist"
mkdir -p "$LAUNCH_AGENTS"
QUOTA_PLIST_TMP="$(mktemp)"
sed -e "s#__PYTHON3__#$PYTHON3#g" -e "s#__RUNTIME__#$RUNTIME#g" \
    "$SCRIPT_DIR/src/quota_polling/$QUOTA_LABEL.plist.template" > "$QUOTA_PLIST_TMP"
if [ -f "$QUOTA_REAL_PLIST" ] && diff -q "$QUOTA_PLIST_TMP" "$QUOTA_REAL_PLIST" >/dev/null 2>&1; then
    rm -f "$QUOTA_PLIST_TMP"
    ok "quota poll LaunchAgent"
else
    mv "$QUOTA_PLIST_TMP" "$QUOTA_REAL_PLIST"
    installed "quota poll LaunchAgent (ticks every 60s, both pollers self-throttle)"
fi
ln -sf "$QUOTA_REAL_PLIST" "$QUOTA_LINK_PLIST"
if [ -z "${AGENT_STATUSLINE_SKIP_LAUNCHD:-}" ]; then
    launchctl bootout "gui/$(id -u)" "$QUOTA_LINK_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$QUOTA_LINK_PLIST"
fi

step "codex status-line patch"
if command -v codex >/dev/null 2>&1; then
    if bash "$SCRIPT_DIR/codex-patch/install-codex-statusline-patch.sh"; then
        ok "Codex status-line patch"
    else
        fail "Codex status-line patch"
    fi
else
    skip "Codex status-line patch (Codex not installed)"
fi

step "codex config"
CONFIG="$HOME/.codex/config.toml"
DESIRED="$SCRIPT_DIR/codex-patch/codex_tui.toml"

if ! command -v codex >/dev/null 2>&1; then
    skip "Codex status line (Codex not installed)"
else
    CODEX_CONFIG="$CONFIG" CODEX_DESIRED="$DESIRED" "$PYTHON3" "$SCRIPT_DIR/codex-patch/merge_codex_config.py"
fi

echo ""
