#!/usr/bin/env python3
"""Merges codex_tui.toml's [tui] status-line keys into ~/.codex/config.toml,
preserving everything else in the file untouched. Run by install.sh's
"codex config" step, which sets CODEX_CONFIG (the real config.toml) and
CODEX_DESIRED (codex_tui.toml, this directory) as env vars.
"""
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

owned = ("status_line", "status_line_use_colors")
current_tui = current.get("tui", {})
if all(current_tui.get(key) == desired[key] for key in owned) and "status_line_command" not in current_tui:
    print("  \033[32m✓\033[0m status line")
    sys.exit(0)

lines = text.splitlines()
table_re = re.compile(r"^\s*\[([^][]+)]\s*(?:#.*)?$")
assignment_re = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*=")

# Older installers wrote a table that Codex never read. Remove it as a
# self-migrating cleanup; the patched binary uses CODEX_STATUS_LINE_COMMAND or
# ~/.codex/statusline-command.sh directly.
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
