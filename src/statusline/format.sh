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

STATUSLINE_SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

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

statusline_spinner_frame() {
    local now="$1" output_name="$2"
    local index=$(( (10#$now) % 10 ))
    printf -v "$output_name" '%s' "${STATUSLINE_SPINNER_FRAMES[$index]}"
}

# statusline_format_remaining - render a countdown in seconds as the
# smallest unit that stays readable ("45m", "4h", "4d15h"), rounding to the
# nearest unit at whatever granularity is displayed rather than truncating,
# so e.g. 23h59m shows as "1d" instead of "0d23h".
statusline_format_remaining() {
    local remain="$1" output_name="$2"
    local minutes hours days rem_hours result
    [ "$remain" -lt 0 ] && remain=0

    minutes=$(( (remain + 30) / 60 ))
    [ "$minutes" -lt 1 ] && minutes=1

    if [ "$minutes" -lt 60 ]; then
        result="${minutes}m"
    else
        hours=$(( (remain + 1800) / 3600 ))
        if [ "$hours" -lt 24 ]; then
            result="${hours}h"
        else
            days=$(( remain / 86400 ))
            rem_hours=$(( (remain % 86400 + 1800) / 3600 ))
            if [ "$rem_hours" -ge 24 ]; then
                days=$((days + 1))
                rem_hours=0
            fi
            if [ "$rem_hours" -eq 0 ]; then
                result="${days}d"
            else
                result="${days}d${rem_hours}h"
            fi
        fi
    fi
    printf -v "$output_name" '%s' "$result"
}

# statusline_reset_severity_color - gray by default, white as a limit's
# reset gets close, green as it gets really close. Thresholds are a
# percentage of the limit's own period (not an absolute time), so the same
# 15%/5% rule gives sensible absolute cutoffs for both a 5h and a 7d limit.
statusline_reset_severity_color() {
    local remain="$1" period="$2" output_name="$3"
    local ratio_pct selected_color
    [ "$remain" -lt 0 ] && remain=0
    if [ "$period" -le 0 ]; then
        selected_color="$STATUSLINE_GRAY_4"
    else
        ratio_pct=$(( remain * 100 / period ))
        if [ "$ratio_pct" -le 5 ]; then selected_color="$STATUSLINE_GREEN"
        elif [ "$ratio_pct" -le 15 ]; then selected_color="$STATUSLINE_GRAY_1"
        else selected_color="$STATUSLINE_GRAY_4"
        fi
    fi
    printf -v "$output_name" '%s' "$selected_color"
}

# statusline_reset_part - one "<color>4h</>" value for statusline_resets_segment.
# period is the limit's own window in seconds (18000 for 5h, 604800 for 7d),
# used only to scale statusline_reset_severity_color's thresholds.
statusline_reset_part() {
    local now="$1" reset="$2" period="$3" output_name="$4"
    local remain color text
    if ! [[ "$reset" =~ ^[0-9]+$ ]]; then
        printf -v "$output_name" '%s' "${STATUSLINE_GRAY_4}--${STATUSLINE_RESET}"
        return
    fi
    remain=$((reset - now))
    if [ "$remain" -le 0 ]; then
        color="$STATUSLINE_GREEN"
        text="now"
    else
        statusline_reset_severity_color "$remain" "$period" color
        statusline_format_remaining "$remain" text
    fi
    printf -v "$output_name" '%s' "${color}${text}${STATUSLINE_RESET}"
}

# statusline_resets_segment - replaces the old datetime/5h/7d rotating
# carousel with a single always-visible "Resets: 4h, 4d15h" summary, each
# value colored by how close its own limit is to resetting.
statusline_resets_segment() {
    local now="$1" five_reset="$2" week_reset="$3" output_name="$4"
    local five_part week_part
    statusline_reset_part "$now" "$five_reset" 18000 five_part
    statusline_reset_part "$now" "$week_reset" 604800 week_part
    printf -v "$output_name" '%s' \
        "${STATUSLINE_GRAY_4}Resets: ${STATUSLINE_RESET}${five_part}${STATUSLINE_GRAY_4}, ${STATUSLINE_RESET}${week_part}"
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
    filled=$(((pct * width + 50) / 100))
    [ "$filled" -gt "$width" ] && filled="$width"
    empty=$((width - filled))
    printf -v fill '%*s' "$filled" ''
    printf -v pad '%*s' "$empty" ''
    result="${color}${fill// /█}${STATUSLINE_BAR_EMPTY}${pad// /░}${STATUSLINE_RESET}"
    printf -v "$output_name" '%s' "$result"
}

statusline_limit_segment() {
    local label="$1" pct="$2" resets="$3" now="$4" source="$5" output_name="$6"
    local color bar remain hours minutes result tag
    tag="${source:+ (${source})}"
    statusline_severity_color "$pct" 70 color
    if [ "$pct" -ge 100 ] && [ -n "$resets" ]; then
        if [[ "$resets" =~ ^[0-9]+$ ]]; then
            remain=$((resets - now)); [ "$remain" -lt 0 ] && remain=0
            hours=$((remain / 3600)); minutes=$(((remain % 3600) / 60))
            result="${STATUSLINE_RED}${label} Blocked - resets in ${hours}h ${minutes}m${tag}${STATUSLINE_RESET}"
        else
            result="${STATUSLINE_RED}${label} Blocked - resets ${resets}${tag}${STATUSLINE_RESET}"
        fi
    else
        statusline_bar "$pct" 8 "$color" bar
        result="${color}${label}${STATUSLINE_RESET} [${bar}] ${color}${pct}%${tag}${STATUSLINE_RESET}"
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

# statusline_common_segments - the metrics/git/host-color/path/limit segment
# assembly shared byte-for-byte by both providers. Not a general-purpose
# primitive like the functions above (no output_name params, unlike the rest
# of this file) - it reads $cwd/$now/$context_pct/$five_pct/$five_reset/
# $week_pct/$week_reset/$lib_dir and sets $git_segment/$host_color/
# $display_cwd/$context_segment/$five_segment/$week_segment/$memory_segment
# by relying on the caller already using those exact names (both providers
# do, by convention), since explicit passing of 7 inputs + 7 outputs would be
# far noisier than the two identically-named call sites it serves.
statusline_common_segments() {
    local metrics_cache="$STATUSLINE_STATE_DIR/system/metrics"
    statusline_refresh_if_stale "$metrics_cache" 30 system-metrics 3 1 "$now" \
        bash "$lib_dir/refresh-metrics.sh"
    local mem_used="" mem_total="" mem_pct=0
    if [ -f "$metrics_cache" ]; then
        IFS="$STATUSLINE_FIELD_SEPARATOR" read -r mem_used mem_total mem_pct < "$metrics_cache"
    fi

    git_segment=""
    if statusline_git_cache_paths "$cwd"; then
        statusline_refresh_if_stale "$STATUSLINE_GIT_LOCAL_CACHE" 8 \
            "git-$STATUSLINE_GIT_KEY-local" 3 1 "$now" \
            bash "$lib_dir/refresh-git-local.sh" "$STATUSLINE_GIT_ROOT"
        statusline_refresh_if_stale "$STATUSLINE_GIT_REMOTE_CACHE" 30 \
            "git-$STATUSLINE_GIT_KEY-remote" 3 1 "$now" \
            bash "$lib_dir/refresh-git-remote.sh" "$STATUSLINE_GIT_ROOT"

        local branch="" untracked=0 unstaged=0 staged=0 conflicts=0 ahead=0 behind=0
        [ -f "$STATUSLINE_GIT_LOCAL_CACHE" ] && \
            IFS="$STATUSLINE_FIELD_SEPARATOR" read -r branch untracked unstaged staged conflicts \
                < "$STATUSLINE_GIT_LOCAL_CACHE"
        [ -f "$STATUSLINE_GIT_REMOTE_CACHE" ] && \
            IFS="$STATUSLINE_FIELD_SEPARATOR" read -r ahead behind < "$STATUSLINE_GIT_REMOTE_CACHE"
        statusline_git_segment "$branch" "$untracked" "$unstaged" "$staged" \
            "$conflicts" "$ahead" "$behind" git_segment
    fi

    statusline_read_static
    printf -v host_color '\033[38;5;%sm' "$STATUSLINE_HOST_COLOR"
    statusline_display_path "$cwd" display_cwd

    statusline_context_segment "$context_pct" context_segment
    statusline_limit_segment 5h "$five_pct" "$five_reset" "$now" "${quota_source:-}" five_segment
    statusline_limit_segment 7d "$week_pct" "$week_reset" "$now" "${quota_source:-}" week_segment

    memory_segment=""
    if [ -n "$mem_used" ] && [ -n "$mem_total" ]; then
        local memory_color
        statusline_severity_color "$mem_pct" 70 memory_color
        memory_segment="    ${memory_color}💾 ${mem_used}G/${mem_total}G${STATUSLINE_RESET}"
    fi
}
