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
        (.project_name | text("")),
        (.thread_id | text("")),
        (.thread_title | text("")),
        (.run_state | text("")),
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
project="${values[3]:-}"
thread_id="${values[4]:-}"
thread_title="${values[5]:-}"
run_state="${values[6]:-}"
permissions="${values[7]:-}"
approval="${values[8]:-}"
context_pct="${values[9]:-0}"
payload_five_pct="${values[10]:-}"
payload_five_reset="${values[11]:-}"
payload_week_pct="${values[12]:-}"
payload_week_reset="${values[13]:-}"
now="${values[14]:-0}"
page=$((now / 4 % 3 + 1))

statusline_touch_heartbeat codex "$now"

model_display="$model"
[ -n "$reasoning" ] && model_display="$model ($reasoning)"

quota_cache="$STATUSLINE_STATE_DIR/quota/codex"
if [ -n "$payload_five_pct" ] || [ -n "$payload_week_pct" ]; then
    statusline_write_values_if_stale "$quota_cache" 60 codex-quota 4 "$now" \
        "$payload_five_pct" "$payload_five_reset" "$payload_week_pct" "$payload_week_reset"
fi
# Empty when unknown: the segment then shows a dash, not a made-up 0%.
five_pct="$payload_five_pct"; five_reset="$payload_five_reset"
week_pct="$payload_week_pct"; week_reset="$payload_week_reset"
statusline_overlay_quota_cache "$quota_cache"

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

rotate=""
if [ "$page" -eq 2 ]; then
    rotate_index=$((now / 12 % 2 + 1))
    statusline_rotating_time "$rotate_index" "" "$week_reset" "$five_reset" rotate
fi
rotate_segment=""
[ -n "$rotate" ] && rotate_segment="    ${rotate}"

line_1="${STATUSLINE_GRAY_1}🤖 ${model_display}${STATUSLINE_RESET}    ${host_color}🖥️  ${STATUSLINE_HOSTNAME}${STATUSLINE_RESET}    ${STATUSLINE_GRAY_2}📂 ${display_cwd}${STATUSLINE_RESET}${git_segment}"
line_2="${STATUSLINE_GRAY_4}🆔 ${thread_id}${rotate_segment}${STATUSLINE_RESET}${extra_segment}"
line_3="${context_segment}    ${five_segment}    ${week_segment}${memory_segment}"

case "$page" in
    1) line="$line_1" ;;
    2) line="$line_2" ;;
    3) line="$line_3" ;;
esac

# Dedicated, independently-rotated debug log (not the shared statusline.log -
# see its own per-render comment) for TODO.md's "stray trailing character"
# carousel glitch: %q escapes every byte unambiguously, so a corrupt render
# is visible here even if it's invisible/misleading on screen, and this
# proves whether the stray character was ever in OUR output (a bug here) or
# only appears after Codex's own TUI redraws a shorter line over a longer
# one (a bug upstream in the patched Codex binary, not this script).
statusline_log_event "$now" carousel_frame "page=$page line=$(printf '%q' "$line")" \
    "$STATUSLINE_LOG_DIR/codex-carousel.log" 262144
printf '%s\n' "$line"
