#!/bin/bash
# Prints live Claude quotas as: 5h_pct FS 5h_reset_epoch FS 7d_pct FS 7d_reset_epoch.
# Cache freshness, locking, timeouts, and atomic writes are owned by
# statusline-cache.sh; this file performs one refresh attempt only.
#
# This is a rare-path fallback now: claude-statusline-command.sh prefers the
# live stdin `rate_limits` payload directly (see
# lib/statusline-push-claude-quota.sh), falling back to this cached value
# only for a session that hasn't sent its first message yet. Reads the
# latest reading from quota/poll_claude.py's shared log instead of hitting
# Anthropic's usage endpoint directly - that poller is this account's single
# fixed-cadence, session-count-independent caller of that endpoint (see
# quota/AGENTS.md); a second independent poller here duplicated that traffic
# and caused 429s during busy multi-session hours.
set -uo pipefail

separator=$'\034'
log_file="$HOME/opt/agent-statusline/data/utilization-log.jsonl"

fail_read() {
    printf 'Claude quota read: %s\n' "$1" >&2
    exit 1
}

[ -f "$log_file" ] || fail_read "quota log not found at $log_file"

# The shared log now interleaves three sources - claude/codex poll rows plus
# frequent claude_statusline push rows - so a busy session can push poll
# rows further back in the tail than the old two-source file did. 200 lines
# comfortably covers the most recent successful "claude" poll reading even
# during a heavily active session between poll ticks.
result="$(tail -n 200 "$log_file" | jq -n -jr --arg separator "$separator" '
    def epoch:
        if . == null then ""
        # jq only accepts whole-second UTC timestamps ending in Z. The API
        # also emits equivalent fractional-second `+00:00` timestamps.
        else sub("\\.[0-9]+\\+00:00$"; "Z")
            | sub("\\+00:00$"; "Z")
            | sub("\\.[0-9]+Z$"; "Z")
            | fromdateiso8601
            | tostring
        end;
    [inputs]
    | map(select(((.source // "claude") == "claude") and (.api != null)))
    | if length == 0 then empty else last end
    | .api
    | [
        ((.five_hour.utilization // 0) | round | tostring),
        (.five_hour.resets_at | epoch),
        ((.seven_day.utilization // 0) | round | tostring),
        (.seven_day.resets_at | epoch)
      ] | join($separator)
' 2>/dev/null)"

[ -n "$result" ] || fail_read "no successful Claude reading found in the last 40 log lines"

printf '%s\n' "$result"
