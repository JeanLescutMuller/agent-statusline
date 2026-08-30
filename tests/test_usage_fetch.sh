#!/bin/bash
# Unit tests for lib/statusline-usage-fetch.sh. Never touches the real
# Keychain or network: `security` and `curl` are stubbed via PATH, and the
# script's own jq epoch-parsing filter is extracted (not re-typed) and run
# against fixture JSON so it can be checked in isolation too.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

USAGE_FETCH="$REPO_ROOT/lib/statusline-usage-fetch.sh"
SEP=$'\034'

if [ "$(uname -s)" != "Darwin" ]; then
    section "(skipped: usage-fetch's credential path here is macOS Keychain-specific)"
    harness_summary
fi

stub_bin="$(mktemp -d "${TMPDIR:-/tmp}/agent-statusline-stubbin.XXXXXX")"
trap 'rm -rf "$stub_bin"' EXIT

cat > "$stub_bin/security" <<'STUB'
#!/bin/bash
case "$SECURITY_STUB_MODE" in
    fail) exit 1 ;;
    no-token) printf '{"other":"stuff"}' ;;
    ok) printf '{"claudeAiOauth":{"accessToken":"tok-123"}}' ;;
esac
STUB
chmod +x "$stub_bin/security"

cat > "$stub_bin/curl" <<'STUB'
#!/bin/bash
cat "$CURL_STUB_RESPONSE_FILE"
STUB
chmod +x "$stub_bin/curl"

section "Keychain lookup fails"
th_run env PATH="$stub_bin:$PATH" SECURITY_STUB_MODE=fail bash "$USAGE_FETCH"
assert_status "exits 1" 1 "$TH_STATUS"
assert_contains "explains the credentials are missing" "$TH_ERR" "credentials not found in macOS Keychain"

section "Keychain returns credentials with no OAuth token"
th_run env PATH="$stub_bin:$PATH" SECURITY_STUB_MODE=no-token bash "$USAGE_FETCH"
assert_status "exits 1" 1 "$TH_STATUS"
assert_contains "explains the token is missing" "$TH_ERR" "OAuth access token missing"

section "successful fetch"
response_file="$stub_bin/response.json"
cat > "$response_file" <<'JSON'
{
    "five_hour": {"utilization": 42.4, "resets_at": "2026-01-01T00:00:00Z"},
    "seven_day": {"utilization": 77.6, "resets_at": "2026-01-05T12:30:00.123456+00:00"}
}
JSON
five_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-01-01T00:00:00Z' '+%s')"
seven_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-01-05T12:30:00Z' '+%s')"

th_run env PATH="$stub_bin:$PATH" SECURITY_STUB_MODE=ok CURL_STUB_RESPONSE_FILE="$response_file" bash "$USAGE_FETCH"
assert_status "exits 0" 0 "$TH_STATUS"
IFS="$SEP" read -r five_pct got_five_epoch seven_pct got_seven_epoch <<< "$TH_OUT"
assert_eq "5h utilization rounds to nearest percent" "42" "$five_pct"
assert_eq "5h reset converts a plain Z timestamp to epoch" "$five_epoch" "$got_five_epoch"
assert_eq "7d utilization rounds to nearest percent" "78" "$seven_pct"
assert_eq "7d reset converts a fractional-second +00:00 timestamp to epoch" "$seven_epoch" "$got_seven_epoch"

section "epoch filter: null resets_at"
jq_program="$(sed -n '/def epoch:/,/join(\$separator)/p' "$USAGE_FETCH")"
out="$(printf '{"five_hour":{"resets_at":null},"seven_day":{"resets_at":null}}' \
    | jq -jr --arg separator "$SEP" "$jq_program")"
IFS="$SEP" read -r five_pct five_reset seven_pct seven_reset <<< "$out"
assert_eq "null resets_at becomes an empty field, not an error" "" "$five_reset"

section "epoch filter: missing utilization defaults to 0"
out="$(printf '{"five_hour":{},"seven_day":{}}' | jq -jr --arg separator "$SEP" "$jq_program")"
IFS="$SEP" read -r five_pct five_reset seven_pct seven_reset <<< "$out"
assert_eq "missing five_hour.utilization defaults to 0" "0" "$five_pct"
assert_eq "missing seven_day.utilization defaults to 0" "0" "$seven_pct"

harness_summary
