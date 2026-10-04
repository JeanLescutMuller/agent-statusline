#!/bin/bash
# Idempotent installer for agent-statusline on a bare machine. No migration
# logic on purpose: across a layout change, run uninstall.sh first.
#
# Deploys the shared cache/format library and the Claude/Codex provider
# adapters, and - when Codex is installed - builds the status-line-command
# patch and sets ~/.codex/config.toml's [tui] status-line keys.
#
# Optional, not deployed here: agent-usage-tracker (README.md's
# "agent-usage-tracker") and bootstrap-home's get_host_color (falls back to a
# default color).
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

# ~/.claude and ~/.codex hold only a symlink back into ~/opt, never a copy
# that can go stale.
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
