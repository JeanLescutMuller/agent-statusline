#!/bin/bash
# Claude payload adapter and three-line renderer backed by shared lazy caches.
set -uo pipefail

lib_dir="${STATUSLINE_LIB_DIR:-$HOME/opt/agent-statusline/src/statusline}"
source "$lib_dir/cache.sh"
source "$lib_dir/format.sh"
statusline_cache_init

clock="$(date '+%s|%m/%d %H:%M:%S|%S')"
IFS='|' read -r now datetime seconds <<< "$clock"

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

# Push the fresh reading to the shared quota log first, before any cache
# overlay below - this must see the raw stdin values, the highest-resolution
# signal there is (see src/statusline/push-claude-quota.sh). Skipped when
# stdin has no rate_limits at all (session hasn't sent a message yet) rather
# than pushing a misleading 0%.
if [ "$has_rate_limits" = "true" ]; then
    bash "$lib_dir/push-claude-quota.sh" \
        "$transcript_path" "$five_pct" "$five_reset" "$week_pct" "$week_reset" \
        >/dev/null 2>&1 || true
fi

model_display="$model"
[ -n "$effort" ] && model_display="$model ($effort)"

quota_cache="$STATUSLINE_STATE_DIR/quota/claude"
# quota_source tags where the displayed five_pct/week_pct actually came from:
#   L = live stdin rate_limits (this render, bypasses the state file entirely)
#   P = src/quota_polling/poll_claude.py's real API poll (writes quota_cache directly)
#   X = another render's live push (src/statusline/push-claude-quota.sh, this
#       session's own or a concurrent one's - writes quota_cache directly)
#   S = degenerate seed - see the write below
#
# Seed a placeholder into the shared state file with observed_at=0 - always
# 0, deliberately never "$now": render time is always >= the push's own
# transcript-derived observed_at for this exact same reading (a message is
# always sent before the render that displays it), so using "$now" here
# would make this render's own seed write silently outrank its own push's
# X write every single time, permanently hiding the X tag - exactly the
# "render/append time is a wrong freshness proxy" trap
# push-claude-quota.sh's own comment warns about. observed_at=0 means this
# only ever matters before the state file has held any real P/X reading -
# once one exists, this is a guaranteed no-op (see
# statusline_write_quota_if_newer's own header comment in cache.sh).
statusline_write_quota_if_newer "$quota_cache" "$five_pct" "$five_reset" \
    "$week_pct" "$week_reset" S 0
# Live stdin values win whenever this render actually has rate_limits -
# they're the freshest signal there is (see the push call above and
# adhoc_quotas_analysis/AGENTS.md §6). The state-file overlay is a fallback
# for the one case stdin can't cover: a session that hasn't sent its first
# message yet.
if [ "$has_rate_limits" = "true" ]; then
    quota_source="L"
else
    statusline_overlay_quota_cache "$quota_cache"
fi

statusline_common_segments

rotate_index=$((10#$seconds / 10 % 3))
statusline_rotating_time "$rotate_index" "$datetime" "$week_reset" "$five_reset" rotate

printf '%s\n' "${STATUSLINE_GRAY_1}🤖 ${model_display}${STATUSLINE_RESET}    ${host_color}🖥️  ${STATUSLINE_HOSTNAME}${STATUSLINE_RESET}    ${STATUSLINE_GRAY_2}📂 ${display_cwd}${STATUSLINE_RESET}${git_segment}"
printf '%s\n' "${STATUSLINE_GRAY_4}🆔 ${session_id}    ${rotate}${STATUSLINE_RESET}"
printf '%s\n' "${context_segment}    ${five_segment}    ${week_segment}${memory_segment}"
