#!/bin/bash
# Prints live Claude quotas as: 5h_pct FS 5h_reset_epoch FS 7d_pct FS 7d_reset_epoch.
# Cache freshness, locking, timeouts, and atomic writes are owned by
# statusline-cache.sh; this file performs one refresh attempt only.
#
# Reads the latest reading from agent-quota-tracker's shared poll log instead
# of hitting Anthropic's usage endpoint directly. agent-quota-tracker already
# runs the single, fixed-cadence, session-count-independent poller for this
# account (see its AGENTS.md) - a second independent poller here duplicated
# that traffic and caused 429s during busy multi-session hours. Soft
# dependency: if agent-quota-tracker isn't installed, this just fails closed
# like the old network fetch did on a Keychain miss.
set -uo pipefail

separator=$'\034'
log_file="$HOME/opt/agent-quota-tracker/data/utilization-log.jsonl"

fail_read() {
    printf 'Claude quota read: %s\n' "$1" >&2
    exit 1
}

[ -f "$log_file" ] || fail_read "agent-quota-tracker log not found at $log_file"

# The poller alternates Claude/Codex rows roughly once per tick; the last 40
# lines comfortably cover the most recent successful Claude reading even
# across a long idle stretch where both pollers still write once per tick.
result="$(tail -n 40 "$log_file" | jq -n -jr --arg separator "$separator" '
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
