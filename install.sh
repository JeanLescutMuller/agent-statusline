#!/bin/bash
# Idempotent installer for agent-statusline.
#
# Deploys the shared cache/format library and the Claude/Codex provider
# adapters, migrates any pre-existing bootstrap-home statusline runtime state,
# deploys the quota-tracking pollers (folded in from the former
# agent-quota-tracker repo - see quota/AGENTS.md) and their LaunchAgent, and -
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
LIB_DIR="$RUNTIME/lib"
LEGACY_RUNTIME="$HOME/opt/bootstrap-home/statusline"
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
for f in "$SCRIPT_DIR"/lib/*.sh; do
    _deploy "$f" "$LIB_DIR/$(basename "$f")"
done

step "provider adapters"
_deploy "$SCRIPT_DIR/providers/claude-statusline-command.sh" "$HOME/.claude/statusline-command.sh"
_deploy "$SCRIPT_DIR/providers/codex-statusline-command.sh" "$HOME/.codex/statusline-command.sh"
rm -f "$HOME/.claude/statusline-usage-fetch.sh"  # stale pre-2026-08-30 helper, replaced by lib/statusline-refresh-claude-quota.sh

step "runtime state"
if [ -d "$LEGACY_RUNTIME" ] && [ ! -d "$RUNTIME/state" ]; then
    mkdir -p "$RUNTIME"
    for sub in state locks logs; do
        [ -d "$LEGACY_RUNTIME/$sub" ] && mv "$LEGACY_RUNTIME/$sub" "$RUNTIME/$sub"
    done
    rmdir "$LEGACY_RUNTIME" 2>/dev/null || true
    installed "migrated runtime state from ~/opt/bootstrap-home/statusline"
else
    mkdir -p "$RUNTIME/state/static" "$RUNTIME/locks" "$RUNTIME/logs"
    ok "runtime state"
fi

step "quota tracker"
mkdir -p "$RUNTIME/quota" "$RUNTIME/data"
for f in "$SCRIPT_DIR"/quota/*.py; do
    _deploy "$f" "$RUNTIME/quota/$(basename "$f")"
done

# One-time: fold in agent-quota-tracker's live deployment. Its own
# install.sh had this exact migrate_legacy() idiom for its four prior
# renames; this applies the same pattern once more, across repos instead of
# within one (see AGENTS.md's "Quota tracking" section). Booting out its
# LaunchAgent here isn't optional: leaving it running alongside the one
# below would mean two independent callers of GET /api/oauth/usage again -
# the exact problem this merge exists to eliminate.
OLD_QUOTA_FOLDER="$HOME/opt/agent-quota-tracker"
OLD_QUOTA_LABEL="com.jeanlescut.agent-quota-tracker"
if [ -d "$OLD_QUOTA_FOLDER" ]; then
    launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS/$OLD_QUOTA_LABEL.plist" 2>/dev/null || true
    rm -f "$LAUNCH_AGENTS/$OLD_QUOTA_LABEL.plist"
    if [ -d "$OLD_QUOTA_FOLDER/data" ]; then
        cp -n "$OLD_QUOTA_FOLDER/data/"* "$RUNTIME/data/" 2>/dev/null || true
    fi
    rm -rf "$OLD_QUOTA_FOLDER"
    installed "migrated from ~/opt/agent-quota-tracker (data/ carried forward, old LaunchAgent booted out)"
fi

QUOTA_LABEL="com.jeanlescut.agent-statusline"
QUOTA_REAL_PLIST="$RUNTIME/$QUOTA_LABEL.plist"
QUOTA_LINK_PLIST="$LAUNCH_AGENTS/$QUOTA_LABEL.plist"
mkdir -p "$LAUNCH_AGENTS"
tee "$QUOTA_REAL_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$QUOTA_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON3</string>
        <string>$RUNTIME/quota/poll_all.py</string>
    </array>

    <!-- Tick every 60s - NOT the same as polling every 60s. Both pollers
         self-throttle most of these ticks away (see each one's module
         docstring): poll_claude.py polls every tick while a Claude Code
         statusline is live, settling to ~5 min once idle; poll_codex.py
         always settles to ~5 min. -->
    <key>StartInterval</key>
    <integer>60</integer>

    <!-- Take a reading immediately when the job is loaded, i.e. at login and
         every time this script re-bootstraps it. Does NOT address sleep
         gaps: StartInterval doesn't fire while the Mac is asleep, though
         launchd does fire once on wake. -->
    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$RUNTIME/logs/quota-poll.log</string>
    <key>StandardErrorPath</key>
    <string>$RUNTIME/logs/quota-poll.err</string>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
ln -sf "$QUOTA_REAL_PLIST" "$QUOTA_LINK_PLIST"
launchctl bootout "gui/$(id -u)" "$QUOTA_LINK_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$QUOTA_LINK_PLIST"
installed "quota poll LaunchAgent (ticks every 60s, both pollers self-throttle)"

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
CODEX_CONFIG="$CONFIG" CODEX_DESIRED="$DESIRED" "$PYTHON3" <<'PY'
import os
import re
import sys
import tomllib
from pathlib import Path

config_path = Path(os.environ["CODEX_CONFIG"])
desired_path = Path(os.environ["CODEX_DESIRED"])

# Keep the source template portable across macOS and Linux while writing the
# absolute path required by the currently deployed Codex process launcher.
home_toml = str(Path.home()).replace("\\", "\\\\").replace('"', '\\"')
desired_text = desired_path.read_text().replace("__HOME__", home_toml)
desired = tomllib.loads(desired_text)["tui"]

try:
    text = config_path.read_text()
except FileNotFoundError:
    text = ""

try:
    current = tomllib.loads(text) if text.strip() else {}
except tomllib.TOMLDecodeError as exc:
    print(f"  \033[31m✗\033[0m Codex config is invalid TOML - not touching it: {exc}")
    sys.exit(1)

owned = ("status_line", "status_line_use_colors", "status_line_command")
current_tui = current.get("tui", {})
if all(current_tui.get(key) == desired[key] for key in owned):
    print("  \033[32m✓\033[0m status line")
    sys.exit(0)

lines = text.splitlines()
table_re = re.compile(r"^\s*\[([^][]+)]\s*(?:#.*)?$")
assignment_re = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*=")

# This project owns the complete nested command table. Remove an old copy
# before inserting the desired one, so refresh-interval changes never create
# duplicate TOML tables.
nested_start = None
nested_end = None
for index, line in enumerate(lines):
    match = table_re.match(line)
    if not match:
        continue
    if match.group(1).strip() == "tui.status_line_command":
        nested_start = index
        continue
    if nested_start is not None:
        nested_end = index
        break
if nested_start is not None:
    if nested_end is None:
        nested_end = len(lines)
    del lines[nested_start:nested_end]

# Locate the plain [tui] table. Dotted/nested TUI tables are separate sections.
tui_start = None
tui_end = None
for index, line in enumerate(lines):
    match = table_re.match(line)
    if not match:
        continue
    if match.group(1).strip() == "tui":
        tui_start = index
        continue
    if tui_start is not None and tui_end is None:
        tui_end = index
        break

if tui_start is None:
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend(desired_text.strip().splitlines())
else:
    if tui_end is None:
        tui_end = len(lines)

    # Drop only assignments owned here. Track bracket depth so a hand-written
    # multiline status_line array is removed as one value.
    kept = []
    index = tui_start + 1
    while index < tui_end:
        match = assignment_re.match(lines[index])
        if not match or match.group(1) not in owned:
            kept.append(lines[index])
            index += 1
            continue

        value = lines[index].split("=", 1)[1]
        depth = value.count("[") - value.count("]")
        index += 1
        while depth > 0 and index < tui_end:
            depth += lines[index].count("[") - lines[index].count("]")
            index += 1

    while kept and not kept[-1].strip():
        kept.pop()
    desired_lines = desired_text.strip().splitlines()[1:]
    lines[tui_start + 1:tui_end] = kept + desired_lines

new_text = "\n".join(lines).rstrip() + "\n"
# Parse before replacing the live file, so a bug in the editor cannot corrupt
# an otherwise valid Codex config.
tomllib.loads(new_text)
config_path.parent.mkdir(parents=True, exist_ok=True)
if config_path.exists():
    backup = config_path.with_name(config_path.name + ".bak")
    backup.write_text(text)
tmp = config_path.with_name(config_path.name + ".tmp")
tmp.write_text(new_text)
tmp.replace(config_path)
print("  \033[32m+\033[0m status line")
PY
fi

echo ""
