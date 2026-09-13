#!/bin/bash
# Prints: branch FS untracked FS unstaged FS staged FS conflicts
set -uo pipefail

root="$1"
separator=$'\034'
branch="$(git -C "$root" branch --show-current 2>/dev/null)"
[ -n "$branch" ] || branch="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)" || exit 1
counts="$(git -C "$root" status --porcelain=v2 2>/dev/null | awk '
    /^\?/ { untracked++ }
    /^u / { conflicts++ }
    /^1 / || /^2 / {
        if (substr($2,1,1) != ".") staged++
        if (substr($2,2,1) != ".") unstaged++
    }
    END { printf "%d %d %d %d", untracked+0, unstaged+0, staged+0, conflicts+0 }
')" || exit 1
read -r untracked unstaged staged conflicts <<< "$counts"
printf '%s%s%s%s%s%s%s%s%s\n' "$branch" "$separator" "$untracked" "$separator" \
    "$unstaged" "$separator" "$staged" "$separator" "$conflicts"
