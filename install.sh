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
# Deploys the shared cache/format library, the Claude/Codex provider
# adapters, and the scheduled pollers under src/quota_polling/ plus their
# LaunchAgent, and - when Codex is installed - builds/deploys the
# status-line-command patch and wires ~/.codex/config.toml's [tui]
# status-line keys. Does NOT deploy adhoc_quotas_analysis/ - that's
# ad-hoc, run-by-hand research tooling (folded in from the former
# agent-quota-tracker repo - see adhoc_quotas_analysis/AGENTS.md), and per
# this machine's own ~/dev vs ~/opt convention (~/.claude/CLAUDE.md /
# ~/AGENTS.md - ~/opt/ is for what a scheduler runs unattended, not
# anything a human runs by hand) it stays in ~/dev/agent-statusline and
# runs from there, even though it reads/writes this project's live
# ~/opt/agent-statusline/data/.
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

_deploy() {
    local src="$1" target="$2"
    mkdir -p "$(dirname "$target")"
    if [ -f "$target" ] && diff -q "$src" "$target" >/dev/null 2>&1; then
        ok "$(basename "$target")"
        return
    fi
    cp "$src" "$target"
    chmod +x "$target" 2>/dev/null || true
    installed "$(basename "$target")"
}

step "shared cache library"
mkdir -p "$LIB_DIR"
for f in "$SCRIPT_DIR"/src/statusline/*.sh; do
    _deploy "$f" "$LIB_DIR/$(basename "$f")"
done

# Symlink into the runtime copy. Used for the OS/app-mandated locations
# (~/.claude, ~/.codex), which hold only a symlink back into ~/opt - a real
# file there went stale unnoticed once (2026-09-30), and a symlink cannot.
_link() {
    local real="$1" link="$2"
    mkdir -p "$(dirname "$link")"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$real" ]; then
        ok "$link -> $real"
        return
    fi
    ln -sfn "$real" "$link"
    installed "$link -> $real"
}

step "provider adapters"
_deploy "$SCRIPT_DIR/providers/claude-statusline-command.sh" "$RUNTIME/providers/claude-statusline-command.sh"
_deploy "$SCRIPT_DIR/providers/codex-statusline-command.sh" "$RUNTIME/providers/codex-statusline-command.sh"
_link "$RUNTIME/providers/claude-statusline-command.sh" "$HOME/.claude/statusline-command.sh"
_link "$RUNTIME/providers/codex-statusline-command.sh" "$HOME/.codex/statusline-command.sh"

step "runtime state"
# data/<agent>/account.jsonl + data/<agent>/<session-id>.jsonl - see
# USAGE_DATA_REFERENCE.md §1. No migration here: an old-layout data/ is
# converted once, by hand, with adhoc_quotas_analysis/split_by_scope.py.
mkdir -p "$RUNTIME/state/static" "$RUNTIME/locks" "$RUNTIME/logs" "$RUNTIME/data/claude" "$RUNTIME/data/codex"
ok "runtime state"

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

step "telemetry receiver"
# Long-running local OTLP receiver that Claude Code pushes its per-request
# usage events to (src/telemetry/otlp_receiver.py). Only the receiver is
# deployed; merge_claude_env.py and its JSON run from the repo.
mkdir -p "$RUNTIME/src/telemetry"
_deploy "$SCRIPT_DIR/src/telemetry/otlp_receiver.py" "$RUNTIME/src/telemetry/otlp_receiver.py"
OTEL_LABEL="com.jeanlescut.agent-statusline.otel"
OTEL_REAL_PLIST="$RUNTIME/$OTEL_LABEL.plist"
OTEL_LINK_PLIST="$LAUNCH_AGENTS/$OTEL_LABEL.plist"
OTEL_PLIST_TMP="$(mktemp)"
sed -e "s#__PYTHON3__#$PYTHON3#g" -e "s#__RUNTIME__#$RUNTIME#g" \
    "$SCRIPT_DIR/src/telemetry/$OTEL_LABEL.plist.template" > "$OTEL_PLIST_TMP"
if [ -f "$OTEL_REAL_PLIST" ] && diff -q "$OTEL_PLIST_TMP" "$OTEL_REAL_PLIST" >/dev/null 2>&1; then
    rm -f "$OTEL_PLIST_TMP"
    ok "telemetry receiver LaunchAgent"
else
    mv "$OTEL_PLIST_TMP" "$OTEL_REAL_PLIST"
    installed "telemetry receiver LaunchAgent (listens on 127.0.0.1:4318)"
fi
ln -sf "$OTEL_REAL_PLIST" "$OTEL_LINK_PLIST"
if [ -z "${AGENT_STATUSLINE_SKIP_LAUNCHD:-}" ]; then
    # Always restart, so a redeployed otlp_receiver.py takes effect.
    launchctl bootout "gui/$(id -u)" "$OTEL_LINK_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$OTEL_LINK_PLIST"
fi

step "claude telemetry settings"
# Only the keys in src/telemetry/claude_telemetry_env.json, inside `env`.
# Takes effect for Claude sessions started after this.
case "$("$PYTHON3" "$SCRIPT_DIR/src/telemetry/merge_claude_env.py" set)" in
    changed) installed "telemetry env vars in ~/.claude/settings.json (new sessions only)" ;;
    unchanged) ok "telemetry env vars in ~/.claude/settings.json" ;;
    *) fail "telemetry env vars in ~/.claude/settings.json" ;;
esac

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
