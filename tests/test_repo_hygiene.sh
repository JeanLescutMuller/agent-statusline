#!/bin/bash
# Repo-wide checks that don't belong to any one file: every script parses,
# shellcheck passes where available, and the codex-patch/ vs
# src/statusline+providers/ architectural boundary documented in README.md's
# "Architecture" section actually holds (nothing in one tree sources the other).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

section "every shell script parses (bash -n)"
while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT"/}"
    th_run bash -n "$f"
    assert_status "$rel has valid syntax" 0 "$TH_STATUS"
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -print0)

section "every Python script compiles (python3 -m py_compile)"
while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT"/}"
    th_run python3 -m py_compile "$f"
    assert_status "$rel has valid syntax" 0 "$TH_STATUS"
done < <(find "$REPO_ROOT/codex-patch" -name '*.py' -print0)

section "shellcheck (if available)"
if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
        rel="${f#"$REPO_ROOT"/}"
        th_run shellcheck -x "$f"
        assert_status "$rel passes shellcheck" 0 "$TH_STATUS"
    done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -not -path '*/tests/*' -print0)
else
    section "  (skipped: shellcheck not installed)"
fi

section "architecture boundary: codex-patch/ and src/statusline+providers/ don't source each other"
codex_patch_sources_arch="$(grep -rl 'src/statusline\|source.*src/statusline\|providers/' "$REPO_ROOT/codex-patch" 2>/dev/null || true)"
assert_eq "nothing under codex-patch/ sources src/statusline/ or providers/" "" "$codex_patch_sources_arch"

arch_sources_codex_patch="$(grep -rl 'codex-patch' "$REPO_ROOT/src/statusline" "$REPO_ROOT/providers" 2>/dev/null || true)"
assert_eq "nothing under src/statusline/ or providers/ references codex-patch/" "" "$arch_sources_codex_patch"

section "only install.sh/uninstall.sh reach into both trees"
other_crossers="$(grep -rl 'codex-patch' "$REPO_ROOT" \
    --include='*.sh' --exclude-dir=.git --exclude-dir=tests --exclude-dir=codex-patch \
    | grep -v -e '^'"$REPO_ROOT"'/install.sh$' -e '^'"$REPO_ROOT"'/uninstall.sh$' || true)"
assert_eq "no other top-level script references codex-patch/" "" "$other_crossers"

section "boundary with agent-usage-tracker: only the Claude provider touches it"
# README.md's "agent-usage-tracker": the Claude provider pipes its payload
# into the tracker's reader and shows the line it prints; nothing else
# here knows the tracker exists.
# Comment lines are ignored.
tracker_refs="$(grep -rn 'agent-usage-tracker\|AGENT_USAGE_TRACKER' "$REPO_ROOT/src" "$REPO_ROOT/providers" \
    "$REPO_ROOT/codex-patch" "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" 2>/dev/null \
    | grep -v -e '^[^:]*:[0-9]*: *#' -e '^[^:]*/providers/claude-statusline-command.sh:' || true)"
assert_eq "no other code references agent-usage-tracker" "" "$tracker_refs"

harness_summary
