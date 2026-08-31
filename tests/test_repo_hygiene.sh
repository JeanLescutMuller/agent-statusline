#!/bin/bash
# Repo-wide checks that don't belong to any one file: every script parses,
# shellcheck passes where available, and the codex-patch/ vs lib+providers/
# architectural boundary documented in README.md's "Architecture" section
# actually holds (nothing in one tree sources the other).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

section "every shell script parses (bash -n)"
while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT"/}"
    th_run bash -n "$f"
    assert_status "$rel has valid syntax" 0 "$TH_STATUS"
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -print0)

section "every quota/ Python script compiles (python3 -m py_compile)"
while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT"/}"
    th_run python3 -m py_compile "$f"
    assert_status "$rel has valid syntax" 0 "$TH_STATUS"
done < <(find "$REPO_ROOT/quota" -name '*.py' -print0)

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

section "architecture boundary: codex-patch/ and lib+providers/ don't source each other"
codex_patch_sources_arch="$(grep -rl 'lib/statusline\|source.*lib/\|providers/' "$REPO_ROOT/codex-patch" 2>/dev/null || true)"
assert_eq "nothing under codex-patch/ sources lib/ or providers/" "" "$codex_patch_sources_arch"

arch_sources_codex_patch="$(grep -rl 'codex-patch' "$REPO_ROOT/lib" "$REPO_ROOT/providers" 2>/dev/null || true)"
assert_eq "nothing under lib/ or providers/ references codex-patch/" "" "$arch_sources_codex_patch"

section "only install.sh reaches into both trees"
other_crossers="$(grep -rl 'codex-patch' "$REPO_ROOT" \
    --include='*.sh' --exclude-dir=.git --exclude-dir=tests --exclude-dir=codex-patch \
    | grep -v '^'"$REPO_ROOT"'/install.sh$' || true)"
assert_eq "no other top-level script references codex-patch/" "" "$other_crossers"

harness_summary
