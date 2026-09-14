#!/bin/bash
# Two writes from the same live reading, on every Claude render that has
# rate_limits on stdin:
#   1. Append a row to the append-only history,
#      data/claude-quota-history.jsonl (shared with
#      src/quota_polling/poll_claude.py, disambiguated by `source`) -
#      unconditionally, no freshness check. Nothing reads this file live
#      any more (see statusline_write_quota_if_newer below); it exists
#      purely as raw material for adhoc_quotas_analysis/'s research
#      notebook, so there's nothing to protect by deduplicating it and
#      every guard here was previously in service of a reader that no
#      longer exists.
#   2. Update the shared "latest known quota" state file
#      (state/quota/claude) via statusline_write_quota_if_newer, tagged
#      "X" (push) - but only if this reading is actually newer than
#      whatever's there, so a slow/delayed render can't regress a fresher
#      poll or another session's more recent push. This is what makes a
#      brand-new session's fallback (no rate_limits yet - see
#      providers/claude-statusline-command.sh) reflect other concurrently
#      active sessions immediately, not just the scheduled poller.
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
# Usage: push-claude-quota.sh <transcript_path> <five_pct>
#          <five_reset_iso> <week_pct> <week_reset_iso>
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/cache.sh"

transcript_path="${1:-}" five_pct="${2:-}" five_reset="${3:-}"
week_pct="${4:-}" week_reset="${5:-}"

[ -n "$transcript_path" ] && [ -f "$transcript_path" ] || exit 0

log_file="$HOME/opt/agent-statusline/data/claude-quota-history.jsonl"

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

statusline_write_quota_if_newer "$STATUSLINE_STATE_DIR/quota/claude" \
    "$five_pct" "$five_reset" "$week_pct" "$week_reset" X "$observed_at"
