#!/bin/bash
# Claude payload adapter and three-line renderer backed by shared lazy caches.
set -uo pipefail

lib_dir="${STATUSLINE_LIB_DIR:-$HOME/opt/agent-statusline/src/statusline}"
source "$lib_dir/cache.sh"
source "$lib_dir/format.sh"
statusline_cache_init

# Optional: the separate agent-usage-tracker project. See README.md's
# "agent-usage-tracker" for the whole contract - this file is the only
# place that touches it.
tracker_dir="${AGENT_USAGE_TRACKER_DIR:-$HOME/opt/agent-usage-tracker}"

now="$(date '+%s')"

statusline_touch_heartbeat claude "$now"

payload="$(cat)"

values=()
while IFS= read -r -d '' value; do
    values+=("$value")
done < <(printf '%s' "$payload" | jq -j '
    def text($default): if . == null then $default else tostring end;
    [
        (.model.display_name | text("Claude")),
        (.effort.level | text("")),
        (.cwd | text("?")),
        (.session_id | text("")),
        ((.context_window.used_percentage // 0) | round | tostring),
        # Unknown ("") only when stdin has no rate_limits at all. Within
        # rate_limits, a missing window means no window is open (it expired
        # and none started since): 0%, the same as the API reports then
        # (utilization 0, resets_at null).
        (if .rate_limits == null then "" else (.rate_limits.five_hour.used_percentage // 0) | round | tostring end),
        (.rate_limits.five_hour.resets_at | text("")),
        (if .rate_limits == null then "" else (.rate_limits.seven_day.used_percentage // 0) | round | tostring end),
        (.rate_limits.seven_day.resets_at | text(""))
    ] | .[] | ., "\u0000"
')

model="${values[0]:-Claude}"
effort="${values[1]:-}"
cwd="${values[2]:-?}"
session_id="${values[3]:-}"
context_pct="${values[4]:-0}"
# This session's own reading; empty (a dash) when stdin has no rate_limits.
five_pct="${values[5]:-}"
five_reset="${values[6]:-}"
week_pct="${values[7]:-}"
week_reset="${values[8]:-}"

# Hand this render's raw payload to agent-usage-tracker's reader, unchanged;
# it stores what it needs and prints the account's freshest reading from any
# session, poller or machine (a passed reset already at 0%), so every open
# session shows the same number. Its failures and stderr are ignored. Without
# the tracker (or a line from it), each session shows its own reading.
tracker_reader="$tracker_dir/src/statusline_payload_reader.py"
tracker_line=
if [ -x "$tracker_reader" ]; then
    tracker_line="$(printf '%s' "$payload" | "$tracker_reader" 2>/dev/null)" || tracker_line=
fi
if [ -n "$tracker_line" ]; then
    IFS="$STATUSLINE_FIELD_SEPARATOR" read -r t_five_pct t_five_reset t_week_pct t_week_reset _ _ <<< "$tracker_line"
    if [ -n "$t_five_pct" ]; then
        five_pct="$t_five_pct" five_reset="$t_five_reset" week_pct="$t_week_pct" week_reset="$t_week_reset"
    fi
fi

model_display="$model"
[ -n "$effort" ] && model_display="$model ($effort)"

statusline_common_segments

statusline_resets_segment "$now" "$five_reset" "$week_reset" resets_segment
statusline_advance_spin_index claude spin_index
statusline_spinner_frame "$spin_index" spinner

printf '%s\n' "${STATUSLINE_GRAY_1}🤖 ${model_display}${STATUSLINE_RESET}    ${host_color}🖥️  ${STATUSLINE_HOSTNAME}${STATUSLINE_RESET}    ${STATUSLINE_GRAY_2}📂 ${display_cwd}${STATUSLINE_RESET}${git_segment}"
printf '%s\n' "${STATUSLINE_GRAY_4}🆔 ${session_id}    ${resets_segment}    ${spinner}${STATUSLINE_RESET}"
printf '%s\n' "${context_segment}    ${five_segment}    ${week_segment}${memory_segment}"
