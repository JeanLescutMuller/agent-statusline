#!/bin/bash
# Unit tests for lib/statusline-refresh-git-remote.sh against a real local
# bare "remote" - no network access, everything happens on disk.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

REFRESH="$REPO_ROOT/lib/statusline-refresh-git-remote.sh"
SEP=$'\034'

section "no upstream configured"
repo="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-gitremote.XXXXXX")"
git -C "$repo" init --quiet --initial-branch=main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
printf 'x\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit --quiet -m initial
th_run bash "$REFRESH" "$repo"
assert_status "exits 0 even with nothing to fetch" 0 "$TH_STATUS"
assert_eq "reports 0/0 ahead/behind" "0${SEP}0" "$TH_OUT"
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
assert_eq "0 ahead, 0 behind when in sync" "0${SEP}0" "$TH_OUT"

section "ahead of upstream"
printf 'more\n' > "$clone/file2.txt"
git -C "$clone" add file2.txt
git -C "$clone" commit --quiet -m "local-only commit"
th_run bash "$REFRESH" "$clone"
IFS="$SEP" read -r ahead behind <<< "$TH_OUT"
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
IFS="$SEP" read -r ahead behind <<< "$TH_OUT"
assert_eq "0 ahead" "0" "$ahead"
assert_eq "2 commits behind" "2" "$behind"
rm -rf "$other" "$clone2"

section "fetch failure (upstream unreachable)"
clone3="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-clone3.XXXXXX")"
git clone --quiet "$remote" "$clone3"
git -C "$clone3" remote set-url origin "/nonexistent/path/does-not-exist"
th_run bash "$REFRESH" "$clone3"
assert_status "exits non-zero when the fetch fails" 1 "$TH_STATUS"
rm -rf "$clone3"

rm -rf "$remote"

harness_summary
