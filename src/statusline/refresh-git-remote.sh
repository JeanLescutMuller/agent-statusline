#!/bin/bash
# Prints: ahead FS behind. A failed fetch preserves the previous cache.
set -uo pipefail

root="$1"
separator=$'\034'
git -C "$root" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || {
    printf '0%s0\n' "$separator"
    exit 0
}
git -C "$root" fetch --quiet >/dev/null 2>&1 || exit 1
counts="$(git -C "$root" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null)" || exit 1
read -r ahead behind <<< "$counts"
printf '%s%s%s\n' "${ahead:-0}" "$separator" "${behind:-0}"
