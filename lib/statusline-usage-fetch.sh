#!/bin/bash
# Prints live Claude quotas as: 5h_pct FS 5h_reset_epoch FS 7d_pct FS 7d_reset_epoch.
# Cache freshness, locking, timeouts, and atomic writes are owned by
# statusline-cache.sh; this file performs one refresh attempt only.
set -uo pipefail

separator=$'\034'
token=""

fail_fetch() {
    printf 'Claude quota refresh: %s\n' "$1" >&2
    exit 1
}

if [ "$(uname -s)" = "Darwin" ]; then
    credentials="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)" \
        || fail_fetch "credentials not found in macOS Keychain"
else
    credentials_file="$HOME/.claude/.credentials.json"
    [ -f "$credentials_file" ] || fail_fetch "credentials file not found"
    credentials="$(<"$credentials_file")"
fi

token="$(printf '%s' "$credentials" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
[ -n "$token" ] || fail_fetch "OAuth access token missing from credentials"

curl --fail --silent --show-error --max-time 4 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" \
    | jq -jr --arg separator "$separator" '
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
        [
            ((.five_hour.utilization // 0) | round | tostring),
            (.five_hour.resets_at | epoch),
            ((.seven_day.utilization // 0) | round | tostring),
            (.seven_day.resets_at | epoch)
        ] | join($separator), "\n"
    '
