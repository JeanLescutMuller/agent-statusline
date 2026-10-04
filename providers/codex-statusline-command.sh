#!/bin/bash
# Codex payload adapter and one-line renderer backed by shared lazy caches.
set -uo pipefail

lib_dir="${STATUSLINE_LIB_DIR:-$HOME/opt/agent-statusline/src/statusline}"
source "$lib_dir/cache.sh"
source "$lib_dir/format.sh"
statusline_cache_init

values=()
while IFS= read -r -d '' value; do
    values+=("$value")
done < <(jq -j '
    def text($default): if . == null then $default else tostring end;
    (now | floor) as $now |
    [
        (.model | text("Codex")),
        (.reasoning | text("")),
        (.cwd | text("?")),
        (.thread_id | text("")),
        (.thread_title | text("")),
        (.permissions | text("")),
        (.approval_mode | text("")),
        (.context.used_percentage | text("0")),
        (.rate_limits.five_hour.used_percentage | text("")),
        (.rate_limits.five_hour.resets_at | text("")),
        (.rate_limits.weekly.used_percentage | text("")),
        (.rate_limits.weekly.resets_at | text("")),
        ($now | tostring)
    ] | .[] | ., "\u0000"
')

model="${values[0]:-Codex}"
reasoning="${values[1]:-}"
cwd="${values[2]:-?}"
thread_id="${values[3]:-}"
thread_title="${values[4]:-}"
permissions="${values[5]:-}"
approval="${values[6]:-}"
context_pct="${values[7]:-0}"
# Percents are empty when unknown: the segment then shows a dash.
five_pct="${values[8]:-}"
five_reset="${values[9]:-}"
week_pct="${values[10]:-}"
week_reset="${values[11]:-}"
now="${values[12]:-0}"
page=$((now / 4 % 3 + 1))

statusline_touch_heartbeat codex "$now"

model_display="$model"
[ -n "$reasoning" ] && model_display="$model ($reasoning)"

statusline_common_segments

extra_segment=""
[ -n "$thread_title" ] && extra_segment="${extra_segment}    ${STATUSLINE_BLUE}🏷️  ${thread_title}${STATUSLINE_RESET}"
case "$permissions" in
    "Read Only") permissions="Read" ;;
    "Full Access") permissions="Full" ;;
    "Custom permissions") permissions="Custom" ;;
esac
case "$approval" in
    "Approve for me") approval="Auto" ;;
    "Ask for approval") approval="Ask" ;;
esac
security="$permissions"
[ -n "$approval" ] && security="${security}${security:+/}${approval}"
[ -n "$security" ] && extra_segment="${extra_segment}    ${STATUSLINE_BLUE}🔐 ${security}${STATUSLINE_RESET}"

statusline_resets_segment "$now" "$five_reset" "$week_reset" resets_segment

line_1="${STATUSLINE_GRAY_1}🤖 ${model_display}${STATUSLINE_RESET}    ${host_color}🖥️  ${STATUSLINE_HOSTNAME}${STATUSLINE_RESET}    ${STATUSLINE_GRAY_2}📂 ${display_cwd}${STATUSLINE_RESET}${git_segment}"
line_2="${STATUSLINE_GRAY_4}🆔 ${thread_id}    ${resets_segment}${STATUSLINE_RESET}${extra_segment}"
line_3="${context_segment}    ${five_segment}    ${week_segment}${memory_segment}"

case "$page" in
    1) line="$line_1" ;;
    2) line="$line_2" ;;
    3) line="$line_3" ;;
esac

printf '%s\n' "$line"
