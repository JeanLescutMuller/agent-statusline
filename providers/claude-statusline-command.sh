#!/bin/bash
# Claude payload adapter and three-line renderer backed by shared lazy caches.
set -uo pipefail

lib_dir="${STATUSLINE_LIB_DIR:-$HOME/opt/agent-statusline/src/statusline}"
source "$lib_dir/cache.sh"
source "$lib_dir/format.sh"
statusline_cache_init

# Optional: the separate agent-tracker project. See README.md's
# "agent-tracker" for the whole contract (one file, read here, never
# written) - this file is the only place that touches it.
quota_file="${AGENT_TRACKER_HOME:-$HOME/opt/agent-tracker}/data/claude/quota_latest.json"

now="$(date '+%s')"

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

# The account's freshest reading (any session, poller or machine), kept by
# agent-tracker, so every open session shows the same number. A window whose
# resets_at has passed is at 0% (agent-tracker's FOR_READERS.md rule 8); a
# missing window is at 0%, as on stdin. Without the file (or a readable one),
# each session shows its own reading.
quota_line=
if [ -r "$quota_file" ]; then
    quota_line="$(jq -r --argjson now "$now" '
        def window($w):
            if ($w | type) != "object" then ["0", ""]
            else [
                (if ($w.resets_at | type) == "number" and $w.resets_at <= $now then "0"
                 else ($w.used_percentage // 0) | round | tostring end),
                (if $w.resets_at == null then "" else $w.resets_at | tostring end)
            ] end;
        if type == "object" then (window(.five_hour) + window(.seven_day)) | join("\u001c") else empty end
    ' "$quota_file" 2>/dev/null)" || quota_line=
fi
if [ -n "$quota_line" ]; then
    IFS="$STATUSLINE_FIELD_SEPARATOR" read -r five_pct five_reset week_pct week_reset <<< "$quota_line"
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
