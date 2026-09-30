#!/bin/bash
# Idempotent installer for agent-statusline, for a machine with no prior
# agent-statusline (or predecessor-project) install. Carries no one-time
# migration logic on purpose: if you're moving between incompatible on-disk
# layouts (this repo's own history has had several), run uninstall.sh first
# - it removes everything this script deploys, preserves codex-patch/ (costly
# to rebuild), and flags anything left over as an orphan to check by
# hand - then re-run this script against a clean machine. A bare
# install/uninstall pair is easier to keep correct forever than an
# ever-growing pile of one-off legacy-layout guards in this file.
#
# Deploys the shared cache/format library and the Claude/Codex provider
# adapters, and - when Codex is installed - builds/deploys the
# status-line-command patch and wires ~/.codex/config.toml's [tui]
# status-line keys.
#
# Usage tracking is a separate project, agent-usage-tracker, installed on its
# own. Nothing here deploys or depends on it; the Claude provider uses it
# when it is there (README.md's "agent-usage-tracker").
#
# Depends on bootstrap-home's ~/opt/bootstrap-home/bin/get_host_color being on
# disk (used by the cache library for a deterministic per-host color); its
# absence just falls back to a default color, it is not a hard dependency.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH"; exit 1; }
PYTHON3="$(command -v python3)"  # codex config merge

RUNTIME="$HOME/opt/agent-statusline"
LIB_DIR="$RUNTIME/src/statusline"

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
mkdir -p "$RUNTIME/state/static" "$RUNTIME/locks" "$RUNTIME/logs"
ok "runtime state"

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
