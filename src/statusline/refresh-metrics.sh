#!/bin/bash
# Prints: used_gb FS total_gb FS used_percent
# "used" as resource-guard defines it (repo resource-guard; macOS: app memory + wired + compressed, as Activity Monitor;
# Linux: total - MemAvailable), so the status line and resource-status show the same number. Read from the last line
# resource-guard wrote (one a minute, ~/opt/resource-guard/data/YYYY-MM.tsv: ts dt cpu_pct cpu_max_pct total_gb used_gb ...,
# memory at the minute's worst 5 s) when it is at most 3 min old; otherwise computed here, the same way.
set -uo pipefail

separator=$'\034'
rg="$HOME/opt/resource-guard/data/$(date -u +%Y-%m).tsv"
if [ -r "$rg" ] && tail -n 1 "$rg" | LC_ALL=C awk -F'\t' -v now="$(date +%s)" -v separator="$separator" '
        $1 ~ /^[0-9]+$/ && now - $1 <= 180 && $5 > 0 { printf "%.1f%s%.1f%s%d\n", $6, separator, $5, separator, int($6 / $5 * 100 + 0.5); ok = 1 }
        END { exit !ok }'; then
    exit 0
fi
if [ "$(uname -s)" = "Darwin" ]; then
    total_bytes="$(sysctl -n hw.memsize 2>/dev/null)" || exit 1
    vm_stat | LC_ALL=C awk -v total_bytes="$total_bytes" -v separator="$separator" '
        NR == 1 { for (i=1; i<=NF; i++) if ($i=="of") pagesize=$(i+1)+0; next }
        /^Anonymous pages/ { anonymous=$NF+0 }
        /^Pages purgeable/ { purgeable=$NF+0 }
        /^Pages wired down/ { wired=$NF+0 }
        /^Pages occupied by compressor/ { compressed=$NF+0 }
        END {
            used=(anonymous-purgeable+wired+compressed)*pagesize/1024/1024/1024
            total=total_bytes/1024/1024/1024
            printf "%.1f%s%.1f%s%d\n", used, separator, total, separator, int(used/total*100+0.5)
        }'
else
    LC_ALL=C awk -v separator="$separator" '
        /^MemTotal:/ { total=$2 }
        /^MemAvailable:/ { available=$2 }
        END {
            used=(total-available)/1024/1024
            total_gb=total/1024/1024
            printf "%.1f%s%.1f%s%d\n", used, separator, total_gb, separator, int(used/total_gb*100+0.5)
        }' /proc/meminfo
fi
