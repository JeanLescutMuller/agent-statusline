#!/bin/bash
# Unit tests for lib/statusline-refresh-git-local.sh against real temp repos.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

REFRESH="$REPO_ROOT/lib/statusline-refresh-git-local.sh"
SEP=$'\034'

new_repo() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-gitlocal.XXXXXX")"
    git -C "$dir" init --quiet --initial-branch=main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    printf 'x\n' > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit --quiet -m initial
    printf '%s' "$dir"
}

section "clean repo"
repo="$(new_repo)"
th_run bash "$REFRESH" "$repo"
assert_status "exits 0" 0 "$TH_STATUS"
IFS="$SEP" read -r branch untracked unstaged staged conflicts <<< "$TH_OUT"
assert_eq "reports the checked-out branch" "main" "$branch"
assert_eq "no untracked files" "0" "$untracked"
assert_eq "no unstaged changes" "0" "$unstaged"
assert_eq "no staged changes" "0" "$staged"
assert_eq "no conflicts" "0" "$conflicts"
rm -rf "$repo"

section "untracked file"
repo="$(new_repo)"
printf 'new\n' > "$repo/untracked.txt"
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts <<< "$TH_OUT"
assert_eq "counts the untracked file" "1" "$untracked"
assert_eq "does not also count it as unstaged" "0" "$unstaged"
rm -rf "$repo"

section "unstaged modification"
repo="$(new_repo)"
printf 'changed\n' > "$repo/file.txt"
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts <<< "$TH_OUT"
assert_eq "counts the unstaged change" "1" "$unstaged"
assert_eq "does not count it as staged" "0" "$staged"
rm -rf "$repo"

section "staged addition"
repo="$(new_repo)"
printf 'more\n' > "$repo/added.txt"
git -C "$repo" add added.txt
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts <<< "$TH_OUT"
assert_eq "counts the staged file" "1" "$staged"
assert_eq "does not count it as unstaged" "0" "$unstaged"
rm -rf "$repo"

section "staged + then further unstaged edit on the same file counts both"
repo="$(new_repo)"
printf 'staged-part\n' > "$repo/file.txt"
git -C "$repo" add file.txt
printf 'staged-part\nunstaged-part\n' > "$repo/file.txt"
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts <<< "$TH_OUT"
assert_eq "counts the staged half" "1" "$staged"
assert_eq "counts the unstaged half" "1" "$unstaged"
rm -rf "$repo"

section "merge conflict"
repo="$(new_repo)"
git -C "$repo" checkout --quiet -b feature
printf 'from-feature\n' > "$repo/file.txt"
git -C "$repo" commit --quiet -am feature-change
git -C "$repo" checkout --quiet main
printf 'from-main\n' > "$repo/file.txt"
git -C "$repo" commit --quiet -am main-change
git -C "$repo" merge --quiet feature >/dev/null 2>&1 || true
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts <<< "$TH_OUT"
assert_eq "counts the conflicted file" "1" "$conflicts"
rm -rf "$repo"

section "detached HEAD"
repo="$(new_repo)"
sha="$(git -C "$repo" rev-parse --short HEAD)"
git -C "$repo" checkout --quiet "$sha"
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts <<< "$TH_OUT"
assert_eq "falls back to the short SHA when there's no branch" "$sha" "$branch"
rm -rf "$repo"

section "not a git repo"
plain_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-notgit.XXXXXX")"
th_run bash "$REFRESH" "$plain_dir"
assert_status "exits 1" 1 "$TH_STATUS"
rm -rf "$plain_dir"

harness_summary
