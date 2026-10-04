#!/bin/bash
# Prints: branch FS untracked FS unstaged FS staged FS conflicts FS ahead FS behind
# ahead/behind compare against the local upstream ref, without fetching:
# "behind" only moves after your own fetch or pull.
set -uo pipefail

root="$1"
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
read -r ahead behind < <(git -C "$root" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null)
fields=("$branch" "$untracked" "$unstaged" "$staged" "$conflicts" "${ahead:-0}" "${behind:-0}")
IFS=$'\034'
printf '%s\n' "${fields[*]}"
