#!/bin/bash
# Claude payload adapter and three-line renderer backed by shared lazy caches.
set -uo pipefail

lib_dir="${STATUSLINE_LIB_DIR:-$HOME/opt/agent-statusline/src/statusline}"
source "$lib_dir/cache.sh"
source "$lib_dir/format.sh"
statusline_cache_init

now="$(date '+%s')"

statusline_touch_heartbeat claude "$now"

values=()
while IFS= read -r -d '' value; do
    values+=("$value")
done < <(jq -j '
    def text($default): if . == null then $default else tostring end;
    [
        (.model.display_name | text("Claude")),
        (.effort.level | text("")),
        (.cwd | text("?")),
        (.session_id | text("")),
        ((.context_window.used_percentage // 0) | round | tostring),
        ((.rate_limits.five_hour.used_percentage // 0) | round | tostring),
        (.rate_limits.five_hour.resets_at | text("")),
        ((.rate_limits.seven_day.used_percentage // 0) | round | tostring),
        (.rate_limits.seven_day.resets_at | text("")),
        (.transcript_path | text("")),
        ((.rate_limits.five_hour != null or .rate_limits.seven_day != null) | tostring)
    ] | .[] | ., "\u0000"
')

model="${values[0]:-Claude}"
effort="${values[1]:-}"
cwd="${values[2]:-?}"
session_id="${values[3]:-}"
context_pct="${values[4]:-0}"
five_pct="${values[5]:-0}"
five_reset="${values[6]:-}"
week_pct="${values[7]:-0}"
week_reset="${values[8]:-}"
transcript_path="${values[9]:-}"
has_rate_limits="${values[10]:-false}"

# Push this render's own reading into the shared state file before display
# (see src/statusline/push-claude-quota.sh - tags it X). Skipped when stdin
# has no rate_limits at all (session hasn't sent a message yet).
if [ "$has_rate_limits" = "true" ]; then
    bash "$lib_dir/push-claude-quota.sh" \
        "$transcript_path" "$five_pct" "$five_reset" "$week_pct" "$week_reset" \
        >/dev/null 2>&1 || true
fi

model_display="$model"
[ -n "$effort" ] && model_display="$model ($effort)"

# state/quota/claude always holds the single freshest known reading -
# whichever session's push or the poller last observed - so every render,
# including this one's own push above, just reads it back for display
# (quota_source ends up P or X; see push-claude-quota.sh and
# src/quota_polling/poll_claude.py, the two writers). This is what makes
# concurrently open sessions converge on the same number instead of each
# showing its own possibly-stale last-known reading.
quota_source=""
statusline_overlay_quota_cache "$STATUSLINE_STATE_DIR/quota/claude"

statusline_common_segments

statusline_resets_segment "$now" "$five_reset" "$week_reset" resets_segment
statusline_advance_spin_index claude spin_index
statusline_spinner_frame "$spin_index" spinner

printf '%s\n' "${STATUSLINE_GRAY_1}🤖 ${model_display}${STATUSLINE_RESET}    ${host_color}🖥️  ${STATUSLINE_HOSTNAME}${STATUSLINE_RESET}    ${STATUSLINE_GRAY_2}📂 ${display_cwd}${STATUSLINE_RESET}${git_segment}"
printf '%s\n' "${STATUSLINE_GRAY_4}🆔 ${session_id}    ${resets_segment}    ${spinner}${STATUSLINE_RESET}"
printf '%s\n' "${context_segment}    ${five_segment}    ${week_segment}${memory_segment}"
