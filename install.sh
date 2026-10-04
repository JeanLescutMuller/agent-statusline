#!/bin/bash
# Idempotent installer for agent-statusline on a bare machine. No migration
# logic on purpose: across a layout change, run uninstall.sh first.
#
# Deploys the shared cache/format library and the Claude/Codex provider
# adapters, and - when Codex is installed - builds the status-line-command
# patch and checks ~/.codex/config.toml's [tui] status-line keys.
#
# Optional, not deployed here: agent-usage-tracker (README.md's
# "agent-usage-tracker") and bootstrap-home's get_host_color (falls back to a
# default color).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

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
# Checked, not edited: ~/.codex/config.toml is yours. The patched binary runs
# ~/.codex/statusline-command.sh once [tui] selects the "custom" item.
CONFIG="$HOME/.codex/config.toml"
if ! command -v codex >/dev/null 2>&1; then
    skip "Codex status line (Codex not installed)"
elif python3 - "$CONFIG" <<'EOF'
import sys, tomllib
try:
    d_tui = tomllib.load(open(sys.argv[1], "rb")).get("tui", {})
except (OSError, tomllib.TOMLDecodeError):
    sys.exit(1)
sys.exit(0 if d_tui.get("status_line") == ["custom"] and d_tui.get("status_line_use_colors") is True else 1)
EOF
then
    ok "status line"
else
    fail "add to $CONFIG under [tui]: status_line = [\"custom\"] and status_line_use_colors = true"
fi

echo ""
