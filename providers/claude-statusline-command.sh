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
quota_dir="${AGENT_TRACKER_HOME:-$HOME/opt/agent-tracker}/data/claude"
# Several Claude accounts (2026-11-19, my-setup's claude-account): a session on account NAME (CLAUDE_ACCOUNT, set by
# the wrapper; empty or "a" = the main account) shows its own account's file, quota_latest.NAME.json.
account="${CLAUDE_ACCOUNT:-a}"
case "$account" in *[!a-z0-9_-]*) account=a ;; esac
if [ "$account" = a ]; then quota_file="$quota_dir/quota_latest.json"; else quota_file="$quota_dir/quota_latest.$account.json"; fi

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
[ "$account" != a ] && model_display="$model_display [$account]"

statusline_common_segments

statusline_resets_segment "$now" "$five_reset" "$week_reset" resets_segment
statusline_advance_spin_index claude spin_index
statusline_spinner_frame "$spin_index" spinner

printf '%s\n' "${STATUSLINE_GRAY_1}🤖 ${model_display}${STATUSLINE_RESET}    ${host_color}🖥️  ${STATUSLINE_HOSTNAME}${STATUSLINE_RESET}    ${STATUSLINE_GRAY_2}📂 ${display_cwd}${STATUSLINE_RESET}${git_segment}"
printf '%s\n' "${STATUSLINE_GRAY_4}🆔 ${session_id}    ${resets_segment}    ${spinner}${STATUSLINE_RESET}"
# The other accounts together: "/y%" in dark gray after each of the 5h and 7d numbers, y = the average of the other
# accounts' used % (their quota_latest*.json beside ours; a window reads 0% once its reset has passed, as above; a file
# jq cannot read is left out). Nothing is added when there is no other account.
others_five=""; others_week=""
others="$(for other_file in "$quota_dir"/quota_latest.json "$quota_dir"/quota_latest.*.json; do
    [ -r "$other_file" ] && [ "$other_file" != "$quota_file" ] || continue
    jq -r --argjson now "$now" '
        def pct($w): if ($w | type) != "object" then 0
            elif ($w.resets_at | type) == "number" and $w.resets_at <= $now then 0
            else ($w.used_percentage // 0) end;
        if type == "object" then "\(pct(.five_hour)) \(pct(.seven_day))" else empty end' "$other_file" 2>/dev/null
done)"
if [ -n "$others" ]; then
    read -r others_five others_week < <(printf '%s\n' "$others" | awk '{f+=$1; w+=$2; n++} END {printf "%d %d\n", f/n+0.5, w/n+0.5}')
    [ -n "$five_pct" ] && five_segment="${five_segment}${STATUSLINE_GRAY_4}/${others_five}%${STATUSLINE_RESET}"
    [ -n "$week_pct" ] && week_segment="${week_segment}${STATUSLINE_GRAY_4}/${others_week}%${STATUSLINE_RESET}"
fi
printf '%s\n' "${context_segment}    ${five_segment}    ${week_segment}${memory_segment}"
