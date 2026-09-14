#!/bin/bash
# Removes everything install.sh deploys: the quota-poll LaunchAgent, the
# deployed provider adapters (~/.claude/statusline-command.sh,
# ~/.codex/statusline-command.sh), and the code/cache/log/lock state under
# ~/opt/agent-statusline. Run this before re-installing across an
# incompatible on-disk layout change - see install.sh's own header comment
# for why migration lives here instead of as one-off logic baked into that
# script.
#
# Deliberately preserves two things instead of a blind rm -rf:
# - data/ (claude-quota-history.jsonl, codex-quota-history.jsonl) -
#   irreplaceable quota history, not reproducible if deleted (see
#   adhoc_quotas_analysis/AGENTS.md). Remove it yourself if you really want
#   it gone.
# - codex-patch/ (the cloned source + build.log used to build the patched
#   Codex binary) - the actual patched binary lives outside this tree, under
#   ~/.codex/packages/standalone/; rebuilding this is a real network clone +
#   multi-minute Cargo build, not something an unrelated statusline
#   uninstall should trigger by accident.
#
# Does NOT touch ~/.codex/config.toml's [tui] status-line keys: with the
# provider adapter gone, Codex's patched binary just fails to run a missing
# script and shows nothing for that status-line item - the same graceful
# degradation as if the feature were disabled, not a broken config. Remove
# those keys by hand if you want config.toml fully clean.
#
# Anything left under ~/opt/agent-statusline after that is a genuine orphan
# - not something this script recognizes - and gets listed for you to check
# by hand rather than being silently deleted or silently ignored.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

RUNTIME="$HOME/opt/agent-statusline"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
QUOTA_LABEL="com.jeanlescut.agent-statusline"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} agent-statusline uninstall${NC}"
echo -e "${GREEN}========================================${NC}"

step "quota poll LaunchAgent"
if [ -f "$LAUNCH_AGENTS/$QUOTA_LABEL.plist" ] || [ -f "$RUNTIME/$QUOTA_LABEL.plist" ]; then
    [ -n "${AGENT_STATUSLINE_SKIP_LAUNCHD:-}" ] || \
        launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS/$QUOTA_LABEL.plist" 2>/dev/null || true
    rm -f "$LAUNCH_AGENTS/$QUOTA_LABEL.plist"
    installed "unloaded and removed the LaunchAgent"
else
    ok "LaunchAgent already absent"
fi

step "provider adapters"
for target in "$HOME/.claude/statusline-command.sh" "$HOME/.codex/statusline-command.sh"; do
    if [ -f "$target" ]; then
        rm -f "$target"
        installed "removed $target"
    else
        ok "$target already absent"
    fi
done

step "runtime tree ($RUNTIME)"
if [ -d "$RUNTIME" ]; then
    rm -rf "$RUNTIME/src" "$RUNTIME/state" "$RUNTIME/locks" "$RUNTIME/logs" \
        "$RUNTIME/$QUOTA_LABEL.plist"
    installed "removed deployed code and cache/log/lock state"
    # rmdir only succeeds on an empty directory - an install that never
    # actually collected data (or never built the Codex patch) leaves
    # nothing behind; real content in either is left in place and reported.
    rmdir "$RUNTIME/data" 2>/dev/null
    [ -d "$RUNTIME/data" ] && skip "preserved $RUNTIME/data (irreplaceable quota history)"
    rmdir "$RUNTIME/codex-patch" 2>/dev/null
    [ -d "$RUNTIME/codex-patch" ] && skip "preserved $RUNTIME/codex-patch (expensive to rebuild)"

    orphans="$(find "$RUNTIME" -mindepth 1 -maxdepth 1 \
        ! -name data ! -name codex-patch 2>/dev/null)"
    if [ -n "$orphans" ]; then
        fail "orphan files/dirs under $RUNTIME - not recognized by this script, check by hand:"
        printf '%s\n' "$orphans" | sed 's/^/      /'
    else
        rmdir "$RUNTIME" 2>/dev/null || true
        ok "no orphans found"
    fi
else
    ok "$RUNTIME already absent"
fi

echo ""
