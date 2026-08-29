#!/bin/bash
# Codex payload adapter and one-line renderer backed by shared lazy caches.
set -uo pipefail

lib_dir="${STATUSLINE_LIB_DIR:-$HOME/opt/agent-statusline/lib}"
source "$lib_dir/statusline-cache.sh"
source "$lib_dir/statusline-format.sh"
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

model_display="$model"
[ -n "$reasoning" ] && model_display="$model ($reasoning)"

quota_cache="$STATUSLINE_STATE_DIR/providers/codex"
if [ -n "$payload_five_pct" ] || [ -n "$payload_week_pct" ]; then
    statusline_write_values_if_stale "$quota_cache" 60 codex-quota 4 "$now" \
        "$payload_five_pct" "$payload_five_reset" "$payload_week_pct" "$payload_week_reset"
fi
five_pct="${payload_five_pct:-0}"; five_reset="$payload_five_reset"
week_pct="${payload_week_pct:-0}"; week_reset="$payload_week_reset"
if [ -f "$quota_cache" ]; then
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
    1) printf '%s\n' "$line_1" ;;
    2) printf '%s\n' "$line_2" ;;
    3) printf '%s\n' "$line_3" ;;
esac
