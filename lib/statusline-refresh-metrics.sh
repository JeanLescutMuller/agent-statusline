#!/bin/bash
# Prints: used_gb FS total_gb FS used_percent
set -uo pipefail

separator=$'\034'
if [ "$(uname -s)" = "Darwin" ]; then
    total_bytes="$(sysctl -n hw.memsize 2>/dev/null)" || exit 1
    vm_stat | LC_ALL=C awk -v total_bytes="$total_bytes" -v separator="$separator" '
        NR == 1 { for (i=1; i<=NF; i++) if ($i=="of") pagesize=$(i+1)+0; next }
        /^Pages active/ { active=$NF+0 }
        /^Pages wired down/ { wired=$NF+0 }
        /^Pages occupied by compressor/ { compressed=$NF+0 }
        END {
            used=(active+wired+compressed)*pagesize/1024/1024/1024
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
