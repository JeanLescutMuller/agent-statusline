#!/bin/bash
# Claude payload adapter and three-line renderer backed by shared lazy caches.
set -uo pipefail

lib_dir="${STATUSLINE_LIB_DIR:-$HOME/opt/agent-statusline/lib}"
source "$lib_dir/statusline-cache.sh"
source "$lib_dir/statusline-format.sh"
statusline_cache_init

clock="$(date '+%s|%m/%d %H:%M:%S|%S')"
IFS='|' read -r now datetime seconds <<< "$clock"

# Liveness signal for agent-quota-tracker's dynamic poll cadence: it polls
# Claude's quota faster while this file is fresh (a statusline is actively
# rendering somewhere) and backs off once every session goes idle/closed.
# Content doesn't matter, only mtime - a plain overwrite is fine, no lock.
mkdir -p "$STATUSLINE_STATE_DIR/providers"
printf '%s\n' "$now" > "$STATUSLINE_STATE_DIR/providers/claude.heartbeat" 2>/dev/null || true

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
# signal there is (see lib/statusline-push-claude-quota.sh). Skipped when
# stdin has no rate_limits at all (session hasn't sent a message yet) rather
# than pushing a misleading 0%.
if [ "$has_rate_limits" = "true" ]; then
    bash "$lib_dir/statusline-push-claude-quota.sh" \
        "$transcript_path" "$five_pct" "$five_reset" "$week_pct" "$week_reset" \
        >/dev/null 2>&1 || true
fi

model_display="$model"
[ -n "$effort" ] && model_display="$model ($effort)"

quota_cache="$STATUSLINE_STATE_DIR/providers/claude"
statusline_refresh_if_stale "$quota_cache" 60 claude-quota 5 2 "$now" \
    bash "$lib_dir/statusline-refresh-claude-quota.sh"
if [ ! -f "$quota_cache" ]; then
    statusline_write_values_if_stale "$quota_cache" 60 claude-quota 8 "$now" \
        "$five_pct" "$five_reset" "$week_pct" "$week_reset"
fi
# Live stdin values win whenever this render actually has rate_limits -
# they're the freshest signal there is (see the push call above and
# quota/AGENTS.md §6). The cache overlay is a fallback for the one case
# stdin can't cover: a session that hasn't sent its first message yet.
if [ "$has_rate_limits" != "true" ] && [ -f "$quota_cache" ]; then
    IFS="$STATUSLINE_FIELD_SEPARATOR" read -r cached_five_pct cached_five_reset \
        cached_week_pct cached_week_reset < "$quota_cache"
    [ -n "$cached_five_pct" ] && five_pct="$cached_five_pct"
    [ -n "$cached_five_reset" ] && five_reset="$cached_five_reset"
    [ -n "$cached_week_pct" ] && week_pct="$cached_week_pct"
    [ -n "$cached_week_reset" ] && week_reset="$cached_week_reset"
fi

metrics_cache="$STATUSLINE_STATE_DIR/system/metrics"
statusline_refresh_if_stale "$metrics_cache" 30 system-metrics 3 1 "$now" \
    bash "$lib_dir/statusline-refresh-metrics.sh"
mem_used=""; mem_total=""; mem_pct=0
if [ -f "$metrics_cache" ]; then
    IFS="$STATUSLINE_FIELD_SEPARATOR" read -r mem_used mem_total mem_pct < "$metrics_cache"
fi

git_segment=""
if statusline_git_cache_paths "$cwd"; then
    statusline_refresh_if_stale "$STATUSLINE_GIT_LOCAL_CACHE" 8 \
        "git-$STATUSLINE_GIT_KEY-local" 3 1 "$now" \
        bash "$lib_dir/statusline-refresh-git-local.sh" "$STATUSLINE_GIT_ROOT"
    statusline_refresh_if_stale "$STATUSLINE_GIT_REMOTE_CACHE" 30 \
        "git-$STATUSLINE_GIT_KEY-remote" 3 1 "$now" \
        bash "$lib_dir/statusline-refresh-git-remote.sh" "$STATUSLINE_GIT_ROOT"

    branch=""; untracked=0; unstaged=0; staged=0; conflicts=0; ahead=0; behind=0
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
statusline_limit_segment 5h "$five_pct" "$five_reset" "$now" five_segment
statusline_limit_segment 7d "$week_pct" "$week_reset" "$now" week_segment

memory_segment=""
if [ -n "$mem_used" ] && [ -n "$mem_total" ]; then
    statusline_severity_color "$mem_pct" 70 memory_color
    memory_segment="    ${memory_color}💾 ${mem_used}G/${mem_total}G${STATUSLINE_RESET}"
fi

rotate_index=$((10#$seconds / 10 % 3))
statusline_rotating_time "$rotate_index" "$datetime" "$week_reset" "$five_reset" rotate

printf '%s\n' "${STATUSLINE_GRAY_1}🤖 ${model_display}${STATUSLINE_RESET}    ${host_color}🖥️  ${STATUSLINE_HOSTNAME}${STATUSLINE_RESET}    ${STATUSLINE_GRAY_2}📂 ${display_cwd}${STATUSLINE_RESET}${git_segment}"
printf '%s\n' "${STATUSLINE_GRAY_4}🆔 ${session_id}    ${rotate}${STATUSLINE_RESET}"
printf '%s\n' "${context_segment}    ${five_segment}    ${week_segment}${memory_segment}"
