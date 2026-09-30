#!/bin/bash
# Two writes from the same live reading, on every Claude render that has
# rate_limits on stdin - this is the *only* way state/quota/claude gets
# real Claude data (besides src/quota_polling/poll_claude.py's poll, tag
# P); providers/claude-statusline-command.sh always displays whatever ends
# up in that file, live render or not, so this write is the entire path to
# the screen:
#   1. Append a row to the append-only account-scope history,
#      data/claude/account.jsonl (shared with poll_claude.py, disambiguated
#      by `source`), and a row to this session's own session-scope file,
#      data/claude/<session_id>.jsonl - only when
#      the transcript gives a precise observed_at (the last message's own
#      timestamp - see below); skipped otherwise, since a fabricated
#      timestamp would degrade the log's research value. Unconditional, no
#      dedup - nothing reads this file live any more, so there's nothing to
#      protect by comparing against previous rows.
#   2. Update state/quota/claude via statusline_write_quota_if_newer, tagged
#      "X", using that same precise observed_at when available, or "now" as
#      a best-effort fallback when there's no usable transcript - still a
#      live reading either way, just without a precise "as of" moment -
#      but only if this reading is actually newer than whatever's already
#      there, so a slow/delayed render can't regress a fresher poll or
#      another session's more recent push.
#
# Free: rides `rate_limits`, already present on every render's stdin
# payload, no network call of its own. See adhoc_quotas_analysis/AGENTS.md's
# "GET /api/oauth/usage 429s" investigation for why this exists - the
# poller's endpoint is unreliable (~21% 429 rate), this path never is.
#
# Called unconditionally on every render, deliberately NOT gated by the
# usual TTL/lock cache machinery in cache.sh - it must catch a
# message that landed sometime in the last render interval, not just once
# every 60s. Always exits 0: a failure here must never break the visible
# statusline.
#
# The scope split (USAGE_DATA_REFERENCE.md §1) is a hard rule: quota
# percent is account-scope only - the meter is one account-level number, so
# a percent in a session file would be read as "this session's usage", which
# is undefined. Hence:
#   - account row: the percents and resets, plus `observed_by_session` (the
#     session that was rendering when the reading was taken - who observed
#     it, not whose usage it is). No per-session cost.
#   - session row: session_cost_usd (the payload's cumulative
#     cost.total_cost_usd), model_id, and the raw `prompt_cache` object
#     (session cache statistics and miss diagnostics, persisted nowhere else
#     - USAGE_DATA_SOURCES.md §3.1; `null` when absent or not valid JSON).
#     Never a percent. Written only when session_id is a plain UUID-like
#     token, since it becomes a file name.
# The two scopes join on observed_at.
#
# Percents arrive unrounded (Claude Code sends floats): the account row
# keeps them as-is, the state file gets them rounded, since everything that
# reads it for display does integer arithmetic.
#
# Usage: push-claude-quota.sh <transcript_path> <five_pct>
#          <five_reset_iso> <week_pct> <week_reset_iso>
#          [session_id] [session_cost_usd] [prompt_cache_json] [model_id]
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/cache.sh"

transcript_path="${1:-}" five_pct="${2:-}" five_reset="${3:-}"
week_pct="${4:-}" week_reset="${5:-}" session_id="${6:-}"
session_cost_usd="${7:-}" prompt_cache_json="${8:-}" model_id="${9:-}"
now="$(date +%s)"

[ -n "$five_pct" ] || exit 0

# Some trailing transcript entries (snapshot/compact bookkeeping) carry no
# `timestamp` - scan back a few lines for the last one that does. observed_at
# is when Claude Code's in-memory rate-limit state actually became true (the
# transcript's own last message timestamp) - not "now": render/append time
# is always later than the reading it's describing, so treating it as the
# freshness stamp would make every render look newer than the render before
# it even when nothing changed, drowning out genuinely newer readings.
#
# The UTC timestamp is converted by plain calendar arithmetic (Howard
# Hinnant's days_from_civil), not jq's fromdateiso8601: jq 1.6 on macOS goes
# through the local timezone and returns an epoch one hour too late whenever
# that zone is in daylight-saving time. Only UTC timestamps ("Z" or "+00:00",
# optional fractional seconds) are accepted; anything else yields no
# observed_at, same as a transcript with no timestamp.
observed_at=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    observed_at="$(tail -n 20 "$transcript_path" 2>/dev/null | jq -n -r '
        def epoch:
            capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(\\.[0-9]+)?(Z|\\+00:00)$")
            | map_values(tonumber)
            | (if .mo <= 2 then .y - 1 else .y end) as $y
            | (($y / 400) | floor) as $era
            | ($y - $era * 400) as $yoe
            | (((153 * (if .mo > 2 then .mo - 3 else .mo + 9 end) + 2) / 5 | floor) + .d - 1) as $doy
            | ($yoe * 365 + (($yoe / 4) | floor) - (($yoe / 100) | floor) + $doy) as $doe
            | ($era * 146097 + $doe - 719468) * 86400 + .h * 3600 + .mi * 60 + .s;
        [inputs | select(.timestamp != null) | .timestamp]
        | if length == 0 then empty else last end
        | epoch
    ' 2>/dev/null)"
fi

if [ -n "$observed_at" ]; then
    data_dir="$HOME/opt/agent-statusline/data/claude"
    mkdir -p "$data_dir"
    valid_session=false
    [[ "$session_id" =~ ^[A-Za-z0-9-]{1,128}$ ]] && [ "$session_id" != account ] && valid_session=true
    rows="$(jq -nc \
        --argjson ts "$now" \
        --arg iso "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --argjson observed_at "$observed_at" \
        --argjson five_pct "$five_pct" \
        --argjson week_pct "${week_pct:-0}" \
        --arg five_reset "$five_reset" \
        --arg week_reset "$week_reset" \
        --arg session_id "$session_id" \
        --arg cost "$session_cost_usd" \
        --arg prompt_cache "$prompt_cache_json" \
        --arg model_id "$model_id" \
        --argjson valid_session "$valid_session" '
        def num_or_null: if . == "" then null else (tonumber? // null) end;
        def nullable: if . == "" then null else . end;
        {ts: $ts, iso: $iso, source: "claude_statusline", observed_at: $observed_at} as $common
        # Line 1: account row - percent lives here and only here.
        | ($common + {five_hour_pct: $five_pct, seven_day_pct: $week_pct,
                      five_hour_resets_at: ($five_reset | nullable),
                      seven_day_resets_at: ($week_reset | nullable),
                      observed_by_session: ($session_id | nullable)}),
        # Line 2 (valid session id only): session row - never a percent.
          (if $valid_session then
               $common + {model_id: ($model_id | nullable),
                          session_cost_usd: ($cost | num_or_null),
                          prompt_cache: (if $prompt_cache == "" then null else ($prompt_cache | fromjson? // null) end)}
           else empty end)
    ' 2>/dev/null)"
    # A single write() call under 4KB with the file opened O_APPEND is
    # POSIX-atomic across processes - no locking needed even with many
    # concurrent sessions' statuslines appending to the same account file.
    { IFS= read -r account_row; IFS= read -r session_row; } <<< "$rows"
    [ -n "${account_row:-}" ] && printf '%s\n' "$account_row" >> "$data_dir/account.jsonl"
    [ -n "${session_row:-}" ] && printf '%s\n' "$session_row" >> "$data_dir/$session_id.jsonl"
fi

five_pct_int="$(jq -n --argjson v "$five_pct" '$v | round' 2>/dev/null)" || exit 0
week_pct_int="$(jq -n --argjson v "${week_pct:-0}" '$v | round' 2>/dev/null)" || exit 0
statusline_write_quota_if_newer "$STATUSLINE_STATE_DIR/quota/claude" \
    "$five_pct_int" "$five_reset" "$week_pct_int" "$week_reset" X "${observed_at:-$now}"
