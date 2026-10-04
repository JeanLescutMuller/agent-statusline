#!/bin/bash
# Removes everything install.sh deploys: the provider symlinks in ~/.claude
# and ~/.codex, and the code/cache/log/lock state under ~/opt/agent-statusline.
# Run it before re-installing across a layout change (install.sh carries no
# migration logic). Never touches agent-usage-tracker or ~/.codex/config.toml
# (a missing script just leaves Codex's status-line item empty).
#
# Preserves codex-patch/ (build.log and marker; the patched binary lives
# under ~/.codex/packages/standalone/). Anything else left over is listed as
# an orphan to check by hand, never deleted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

RUNTIME="$HOME/opt/agent-statusline"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} agent-statusline uninstall${NC}"
echo -e "${GREEN}========================================${NC}"

step "provider adapters"
for target in "$HOME/.claude/statusline-command.sh" "$HOME/.codex/statusline-command.sh"; do
    # -L too: a symlink into the runtime tree (what install.sh deploys) is
    # removed even if its target is already gone.
    if [ -L "$target" ] || [ -f "$target" ]; then
        rm -f "$target"
        installed "removed $target"
    else
        ok "$target already absent"
    fi
done

step "runtime tree ($RUNTIME)"
if [ -d "$RUNTIME" ]; then
    # A live render in another session can recreate state/ while rm -rf
    # runs; a few short retries clear that in practice.
    known_targets="src providers state locks logs"
    for target in $known_targets; do
        for attempt in 1 2 3; do
            rm -rf "$RUNTIME/$target" 2>/dev/null
            [ -d "$RUNTIME/$target" ] || break
            sleep 0.5
        done
    done
    installed "removed deployed code and cache/log/lock state"
    # rmdir only succeeds on an empty directory - a Codex patch that was
    # never built leaves nothing behind; real content is kept and reported.
    rmdir "$RUNTIME/codex-patch" 2>/dev/null
    [ -d "$RUNTIME/codex-patch" ] && skip "preserved $RUNTIME/codex-patch (expensive to rebuild)"

    still_racing=""
    for target in $known_targets; do
        [ -d "$RUNTIME/$target" ] && still_racing="$still_racing $target"
    done
    [ -n "$still_racing" ] && fail "couldn't fully remove:$still_racing - most likely another Claude/Codex session is still actively rendering and repopulating it faster than this can clear it; wait for other sessions to finish, then re-run"

    orphans="$(find "$RUNTIME" -mindepth 1 -maxdepth 1 \
        ! -name codex-patch ! -name src ! -name state \
        ! -name locks ! -name logs 2>/dev/null)"
    if [ -n "$orphans" ]; then
        fail "orphan files/dirs under $RUNTIME - not recognized by this script, check by hand:"
        printf '%s\n' "$orphans" | sed 's/^/      /'
    elif [ -z "$still_racing" ]; then
        rmdir "$RUNTIME" 2>/dev/null || true
        ok "no orphans found"
    fi
else
    ok "$RUNTIME already absent"
fi

echo ""
