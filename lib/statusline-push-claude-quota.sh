#!/bin/bash
# Appends a Claude quota reading to the shared quota log whenever the
# statusline's stdin payload carries a genuinely newer observation than the
# last one this same push path logged. Free: rides `rate_limits`, already
# present on every render's stdin payload, no network call of its own. See
# quota/AGENTS.md's "GET /api/oauth/usage 429s" investigation for why this
# exists - the poller's endpoint is unreliable (~21% 429 rate), this path
# never is.
#
# Called unconditionally on every render, deliberately NOT gated by the
# usual TTL/lock cache machinery in statusline-cache.sh - it must catch a
# message that landed sometime in the last render interval, not just once
# every 60s. Always exits 0: a failure here must never break the visible
# statusline.
#
# Usage: statusline-push-claude-quota.sh <transcript_path> <five_pct>
#          <five_reset_iso> <week_pct> <week_reset_iso>
set -uo pipefail

transcript_path="${1:-}" five_pct="${2:-}" five_reset="${3:-}"
week_pct="${4:-}" week_reset="${5:-}"

[ -n "$transcript_path" ] && [ -f "$transcript_path" ] || exit 0

log_file="$HOME/opt/agent-statusline/data/utilization-log.jsonl"

# Some trailing transcript entries (snapshot/compact bookkeeping) carry no
# `timestamp` - scan back a few lines for the last one that does. observed_at
# is when Claude Code's in-memory rate-limit state actually became true (the
# transcript's own last message timestamp) - not "now": render time and
# append time are both wrong proxies that would claim freshness the data
# doesn't have.
observed_at="$(tail -n 20 "$transcript_path" 2>/dev/null | jq -n -r '
    def epoch:
        sub("\\.[0-9]+\\+00:00$"; "Z") | sub("\\+00:00$"; "Z") | sub("\\.[0-9]+Z$"; "Z")
        | fromdateiso8601;
    [inputs | select(.timestamp != null) | .timestamp]
    | if length == 0 then empty else last end
    | epoch
' 2>/dev/null)"
[ -n "$observed_at" ] || exit 0

mkdir -p "$(dirname "$log_file")"

# Compare against this push path's OWN last row specifically - the shared
# log interleaves claude/codex/claude_statusline rows, and reading just the
# tail line can silently compare against the wrong source. poll_claude.py
# hit exactly this bug once (see quota/AGENTS.md's `_last_claude_log_row`
# gotcha) - same discipline applies here.
last_observed_at="$(tail -n 200 "$log_file" 2>/dev/null | jq -n -r '
    [inputs | select(.source == "claude_statusline")]
    | if length == 0 then empty else last end
    | .observed_at // empty
' 2>/dev/null)"

if [ -n "$last_observed_at" ] && [ "$observed_at" -le "$last_observed_at" ] 2>/dev/null; then
    exit 0
fi

row="$(jq -nc \
    --argjson ts "$(date +%s)" \
    --arg iso "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson observed_at "$observed_at" \
    --argjson five_pct "${five_pct:-0}" \
    --argjson week_pct "${week_pct:-0}" \
    --arg five_reset "$five_reset" \
    --arg week_reset "$week_reset" '
    {ts: $ts, iso: $iso, source: "claude_statusline", observed_at: $observed_at,
     five_hour_pct: $five_pct, seven_day_pct: $week_pct,
     five_hour_resets_at: (($five_reset | select(. != "")) // null),
     seven_day_resets_at: (($week_reset | select(. != "")) // null)}
' 2>/dev/null)"
[ -n "$row" ] || exit 0

# A single write() call under 4KB with the file opened O_APPEND is
# POSIX-atomic across processes - no locking needed even with many
# concurrent sessions' statuslines appending to this same file.
printf '%s\n' "$row" >> "$log_file"
