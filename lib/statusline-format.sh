#!/bin/bash
# Shared ANSI styling and segment formatting for both statusline providers.

STATUSLINE_RESET=$'\033[0m'
STATUSLINE_GRAY_1=$'\033[97m'
STATUSLINE_GRAY_2=$'\033[37m'
STATUSLINE_GRAY_3=$'\033[38;5;250m'
STATUSLINE_GRAY_4=$'\033[38;5;240m'
STATUSLINE_GREEN=$'\033[32m'
STATUSLINE_YELLOW=$'\033[33m'
STATUSLINE_RED=$'\033[31m'
STATUSLINE_BLUE=$'\033[38;5;39m'
STATUSLINE_CYAN=$'\033[38;5;51m'
STATUSLINE_PURPLE=$'\033[38;5;141m'
STATUSLINE_BAR_EMPTY=$'\033[38;5;238m'

statusline_display_path() {
    local path="$1" output_name="$2" display
    case "$path" in
        "$HOME") display="~" ;;
        "$HOME"/*) display="~${path#"$HOME"}" ;;
        *) display="$path" ;;
    esac
    printf -v "$output_name" '%s' "$display"
}

statusline_fmt_epoch() {
    local epoch="$1" format="$2"
    if [ "$(uname -s)" = "Darwin" ]; then
        LC_TIME=C date -r "$epoch" "+$format" 2>/dev/null
    else
        LC_TIME=C date -d "@$epoch" "+$format" 2>/dev/null
    fi
}

statusline_ordinal_suffix() {
    case "$1" in
        1|21|31) printf 'st' ;;
        2|22) printf 'nd' ;;
        3|23) printf 'rd' ;;
        *) printf 'th' ;;
    esac
}

statusline_rotating_time() {
    local index="$1" datetime="$2" week_reset="$3" five_reset="$4" output_name="$5"
    local week_day result="$datetime"
    if [ "$index" -eq 1 ] && [[ "$week_reset" =~ ^[0-9]+$ ]]; then
        week_day="$(statusline_fmt_epoch "$week_reset" '%e')"
        week_day="${week_day// /}"
        result="7d reset on $(statusline_fmt_epoch "$week_reset" '%A') ${week_day}$(statusline_ordinal_suffix "$week_day") at $(statusline_fmt_epoch "$week_reset" '%Hh')"
    elif [ "$index" -eq 2 ] && [[ "$five_reset" =~ ^[0-9]+$ ]]; then
        result="5h reset at $(statusline_fmt_epoch "$five_reset" '%Hh%M')"
    fi
    printf -v "$output_name" '%s' "$result"
}

statusline_severity_color() {
    local pct="$1" yellow_threshold="${2:-70}" output_name="$3" selected_color
    if [ "$pct" -ge 90 ]; then selected_color="$STATUSLINE_RED"
    elif [ "$pct" -ge "$yellow_threshold" ]; then selected_color="$STATUSLINE_YELLOW"
    else selected_color="$STATUSLINE_GREEN"
    fi
    printf -v "$output_name" '%s' "$selected_color"
}

statusline_bar() {
    local pct="$1" width="$2" color="$3" output_name="$4"
    local filled empty fill pad result
    filled=$((pct * width / 100))
    [ "$filled" -gt "$width" ] && filled="$width"
    empty=$((width - filled))
    printf -v fill '%*s' "$filled" ''
    printf -v pad '%*s' "$empty" ''
    result="${color}${fill// /█}${STATUSLINE_BAR_EMPTY}${pad// /░}${STATUSLINE_RESET}"
    printf -v "$output_name" '%s' "$result"
}

statusline_limit_segment() {
    local label="$1" pct="$2" resets="$3" now="$4" output_name="$5"
    local color bar remain hours minutes result
    statusline_severity_color "$pct" 70 color
    if [ "$pct" -ge 100 ] && [ -n "$resets" ]; then
        if [[ "$resets" =~ ^[0-9]+$ ]]; then
            remain=$((resets - now)); [ "$remain" -lt 0 ] && remain=0
            hours=$((remain / 3600)); minutes=$(((remain % 3600) / 60))
            result="${STATUSLINE_RED}${label} Blocked - resets in ${hours}h ${minutes}m${STATUSLINE_RESET}"
        else
            result="${STATUSLINE_RED}${label} Blocked - resets ${resets}${STATUSLINE_RESET}"
        fi
    else
        statusline_bar "$pct" 8 "$color" bar
        result="${color}${label}${STATUSLINE_RESET} [${bar}] ${color}${pct}%${STATUSLINE_RESET}"
    fi
    printf -v "$output_name" '%s' "$result"
}

statusline_context_segment() {
    local pct="$1" output_name="$2" color bar result
    statusline_severity_color "$pct" 40 color
    statusline_bar "$pct" 8 "$color" bar
    result="${color}💬 ${STATUSLINE_RESET}[${bar}] ${color}${pct}%${STATUSLINE_RESET}"
    printf -v "$output_name" '%s' "$result"
}

statusline_git_segment() {
    local branch="$1" untracked="$2" unstaged="$3" staged="$4"
    local conflicts="$5" ahead="$6" behind="$7" output_name="$8"
    local working="" sync="" conflict="" result

    [ -n "$branch" ] || { printf -v "$output_name" '%s' ''; return; }
    [ "$untracked" -gt 0 ] && working="${working}${working:+ }${STATUSLINE_CYAN}?${untracked}${STATUSLINE_GRAY_3}"
    [ "$unstaged" -gt 0 ] && working="${working}${working:+ }!${unstaged}"
    [ "$staged" -gt 0 ] && working="${working}${working:+ }${STATUSLINE_BLUE}✚${staged}${STATUSLINE_GRAY_3}"
    [ -n "$working" ] && working=" (${working})"
    [ "$ahead" -gt 0 ] && sync="${sync}⇡${ahead}"
    [ "$behind" -gt 0 ] && sync="${sync}⇣${behind}"
    [ -n "$sync" ] && sync=" ${STATUSLINE_PURPLE}${sync}${STATUSLINE_GRAY_3}"
    [ "$conflicts" -gt 0 ] && conflict=" ${STATUSLINE_RED}(✖${conflicts})${STATUSLINE_GRAY_3}"
    result="    ${STATUSLINE_GRAY_3}🌿 ${branch}${working}${sync}${conflict}${STATUSLINE_RESET}"
    printf -v "$output_name" '%s' "$result"
}
