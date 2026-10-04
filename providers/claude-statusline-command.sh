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
        (.rate_limits.seven_day.resets_at | text("")),
        (.transcript_path | text(""))
    ] | .[] | ., "\u0000"
')

model="${values[0]:-Claude}"
effort="${values[1]:-}"
cwd="${values[2]:-?}"
session_id="${values[3]:-}"
context_pct="${values[4]:-0}"
# Percents are empty when stdin has no rate_limits at all; the segment then
# shows a dash unless a cached reading fills it in below.
five_pct="${values[5]:-}"
five_reset="${values[6]:-}"
week_pct="${values[7]:-}"
week_reset="${values[8]:-}"
transcript_path="${values[9]:-}"

# This repo's own Claude display cache: the freshest reading any open
# session has seen, so concurrent sessions converge on one number instead of
# each showing its own possibly-stale snapshot. A render only writes it when
# its stdin has a reading, stamped with when that reading became true (its
# transcript's last assistant message), and only if that beats what is
# already there. A reading of unknown age (no transcript yet, or no
# assistant message in it) is stamped 0: it fills an empty cache but never
# beats a dated reading - it may be days old.
own_quota="$STATUSLINE_STATE_DIR/quota/claude"
if [ -n "$five_pct" ]; then
    statusline_transcript_observed_at "$transcript_path" observed_at
    statusline_write_quota_if_newer "$own_quota" \
        "$five_pct" "$five_reset" "$week_pct" "$week_reset" X "${observed_at:-0}"
fi

# Hand this render's raw payload to agent-usage-tracker, unchanged, before
# display - it records the quota reading and updates its state file, so the
# read-back below includes this render's own reading. Synchronous but
# fire-and-forget: output and failures are ignored. Skipped when the tracker
# isn't installed.
if [ -x "$tracker_dir/bin/ingest-claude-statusline.sh" ]; then
    printf '%s' "$payload" | "$tracker_dir/bin/ingest-claude-statusline.sh" >/dev/null 2>&1 || true
fi

model_display="$model"
[ -n "$effort" ] && model_display="$model ($effort)"

# Display the freshest reading known: this repo's own cache (any session's
# stdin), or agent-usage-tracker's poller reading (tag P) - useful while no
# session has sent a message. Only P is taken from the tracker: its X
# readings come from these same stdin payloads, which the own cache already
# holds with this repo's own observed_at rule, so trusting the tracker's
# stamping of them would only let its bugs leak into the display. Comparing
# on observed_at means a stale tracker can never freeze the display, and a
# missing one just leaves the own cache.
tracker_quota="$tracker_dir/state/quota/claude"
tracker_source=""
[ -f "$tracker_quota" ] && IFS="$STATUSLINE_FIELD_SEPARATOR" read -r _ _ _ _ tracker_source _ < "$tracker_quota"
[ "$tracker_source" = P ] || tracker_quota=""
statusline_overlay_freshest_quota "$own_quota" ${tracker_quota:+"$tracker_quota"}

statusline_common_segments

statusline_resets_segment "$now" "$five_reset" "$week_reset" resets_segment
statusline_advance_spin_index claude spin_index
statusline_spinner_frame "$spin_index" spinner

printf '%s\n' "${STATUSLINE_GRAY_1}🤖 ${model_display}${STATUSLINE_RESET}    ${host_color}🖥️  ${STATUSLINE_HOSTNAME}${STATUSLINE_RESET}    ${STATUSLINE_GRAY_2}📂 ${display_cwd}${STATUSLINE_RESET}${git_segment}"
printf '%s\n' "${STATUSLINE_GRAY_4}🆔 ${session_id}    ${resets_segment}    ${spinner}${STATUSLINE_RESET}"
printf '%s\n' "${context_segment}    ${five_segment}    ${week_segment}${memory_segment}"
