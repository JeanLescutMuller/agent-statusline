#!/bin/bash
# Unit tests for src/statusline/refresh-git.sh against real temp repos and a
# local bare "remote" - no network access.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

REFRESH="$REPO_ROOT/src/statusline/refresh-git.sh"
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
IFS="$SEP" read -r branch untracked unstaged staged conflicts ahead behind <<< "$TH_OUT"
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
IFS="$SEP" read -r branch untracked unstaged staged conflicts ahead behind <<< "$TH_OUT"
assert_eq "counts the untracked file" "1" "$untracked"
assert_eq "does not also count it as unstaged" "0" "$unstaged"
rm -rf "$repo"

section "unstaged modification"
repo="$(new_repo)"
printf 'changed\n' > "$repo/file.txt"
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts ahead behind <<< "$TH_OUT"
assert_eq "counts the unstaged change" "1" "$unstaged"
assert_eq "does not count it as staged" "0" "$staged"
rm -rf "$repo"

section "staged addition"
repo="$(new_repo)"
printf 'more\n' > "$repo/added.txt"
git -C "$repo" add added.txt
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts ahead behind <<< "$TH_OUT"
assert_eq "counts the staged file" "1" "$staged"
assert_eq "does not count it as unstaged" "0" "$unstaged"
rm -rf "$repo"

section "staged + then further unstaged edit on the same file counts both"
repo="$(new_repo)"
printf 'staged-part\n' > "$repo/file.txt"
git -C "$repo" add file.txt
printf 'staged-part\nunstaged-part\n' > "$repo/file.txt"
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts ahead behind <<< "$TH_OUT"
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
IFS="$SEP" read -r branch untracked unstaged staged conflicts ahead behind <<< "$TH_OUT"
assert_eq "counts the conflicted file" "1" "$conflicts"
rm -rf "$repo"

section "detached HEAD"
repo="$(new_repo)"
sha="$(git -C "$repo" rev-parse --short HEAD)"
git -C "$repo" checkout --quiet "$sha"
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r branch untracked unstaged staged conflicts ahead behind <<< "$TH_OUT"
assert_eq "falls back to the short SHA when there's no branch" "$sha" "$branch"
rm -rf "$repo"

section "not a git repo"
plain_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-notgit.XXXXXX")"
th_run bash "$REFRESH" "$plain_dir"
assert_status "exits 1" 1 "$TH_STATUS"
rm -rf "$plain_dir"

section "no upstream configured"
repo="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-gitremote.XXXXXX")"
git -C "$repo" init --quiet --initial-branch=main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
printf 'x\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit --quiet -m initial
th_run bash "$REFRESH" "$repo"
IFS="$SEP" read -r _ _ _ _ _ ahead behind <<< "$TH_OUT"
assert_eq "reports 0/0 ahead/behind" "0 0" "$ahead $behind"
rm -rf "$repo"

section "up to date with upstream"
remote="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-remote.XXXXXX")"
git init --quiet --bare "$remote"
clone="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-clone.XXXXXX")"
git clone --quiet "$remote" "$clone" 2>/dev/null
git -C "$clone" config user.email test@example.com
git -C "$clone" config user.name Test
printf 'x\n' > "$clone/file.txt"
git -C "$clone" add file.txt
git -C "$clone" commit --quiet -m initial
git -C "$clone" push --quiet -u origin HEAD
th_run bash "$REFRESH" "$clone"
assert_status "exits 0" 0 "$TH_STATUS"
IFS="$SEP" read -r _ _ _ _ _ ahead behind <<< "$TH_OUT"
assert_eq "0 ahead, 0 behind when in sync" "0 0" "$ahead $behind"

section "ahead of upstream"
printf 'more\n' > "$clone/file2.txt"
git -C "$clone" add file2.txt
git -C "$clone" commit --quiet -m "local-only commit"
th_run bash "$REFRESH" "$clone"
IFS="$SEP" read -r _ _ _ _ _ ahead behind <<< "$TH_OUT"
assert_eq "1 commit ahead" "1" "$ahead"
assert_eq "0 behind" "0" "$behind"
git -C "$clone" push --quiet
rm -rf "$clone"

section "behind upstream"
clone2="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-clone2.XXXXXX")"
git clone --quiet "$remote" "$clone2"
git -C "$clone2" config user.email test@example.com
git -C "$clone2" config user.name Test
# Push two more commits from a throwaway clone so $clone2 falls behind.
other="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-other.XXXXXX")"
git clone --quiet "$remote" "$other"
git -C "$other" config user.email test@example.com
git -C "$other" config user.name Test
printf 'a\n' >> "$other/file.txt"
git -C "$other" commit --quiet -am "upstream commit 1"
printf 'b\n' >> "$other/file.txt"
git -C "$other" commit --quiet -am "upstream commit 2"
git -C "$other" push --quiet
th_run bash "$REFRESH" "$clone2"
IFS="$SEP" read -r _ _ _ _ _ ahead behind <<< "$TH_OUT"
assert_eq "no fetch: behind stays 0 until you fetch" "0" "$behind"
git -C "$clone2" fetch --quiet
th_run bash "$REFRESH" "$clone2"
IFS="$SEP" read -r _ _ _ _ _ ahead behind <<< "$TH_OUT"
assert_eq "0 ahead" "0" "$ahead"
assert_eq "2 commits behind" "2" "$behind"
rm -rf "$other" "$clone2"

rm -rf "$remote"

harness_summary
