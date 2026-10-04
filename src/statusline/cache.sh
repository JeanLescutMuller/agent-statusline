#!/bin/bash
# Shared lazy cache primitives for Claude and Codex statusline renderers.

STATUSLINE_RUNTIME_DIR="${STATUSLINE_RUNTIME_DIR:-$HOME/opt/agent-statusline}"
STATUSLINE_STATE_DIR="$STATUSLINE_RUNTIME_DIR/state"
STATUSLINE_LOCK_DIR="$STATUSLINE_RUNTIME_DIR/locks"
STATUSLINE_FIELD_SEPARATOR=$'\034'

statusline_cache_init() {
    [ -d "$STATUSLINE_STATE_DIR" ] && [ -d "$STATUSLINE_LOCK_DIR" ] && return
    mkdir -p "$STATUSLINE_STATE_DIR" "$STATUSLINE_LOCK_DIR"
}

# Fresh = refreshed (or attempted, see statusline_refresh_if_stale) less
# than ttl seconds ago.
statusline_cache_is_fresh() {
    local cache_file="$1" ttl="$2" now="$3" timestamp=""
    [ -f "${cache_file}.timestamp" ] || return 1
    IFS= read -r timestamp < "${cache_file}.timestamp"
    case "$timestamp" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ $((now - timestamp)) -lt "$ttl" ]
}

# A lock is a file holding its creation epoch, created atomically with
# noclobber; one older than stale_after seconds (a killed renderer) is taken
# over. A rare double takeover only means two identical refreshes.
statusline_lock_acquire() {
    local lock_path="$STATUSLINE_LOCK_DIR/$1.lock" stale_after="$2" now="$3" lock_timestamp=""
    if ! (set -C; printf '%s\n' "$now" > "$lock_path") 2>/dev/null; then
        IFS= read -r lock_timestamp < "$lock_path" 2>/dev/null
        case "$lock_timestamp" in
            ''|*[!0-9]*) lock_timestamp=0 ;;
        esac
        [ $((now - lock_timestamp)) -ge "$stale_after" ] || return 1
        printf '%s\n' "$now" > "$lock_path" 2>/dev/null || return 1
    fi
    STATUSLINE_LOCK_PATH="$lock_path"
}

statusline_lock_release() {
    rm -f "${STATUSLINE_LOCK_PATH:-}"
    STATUSLINE_LOCK_PATH=""
}

# statusline_refresh_if_stale <cache_file> <ttl> <lock_key> <lock_stale_after>
# <timeout_seconds> <now> <command...> - reruns command into cache_file once
# ttl has passed, under a lock so only one renderer refreshes. The timestamp
# is stamped before the attempt: a failed or empty refresh keeps the previous
# value until the next ttl instead of being retried on every render. The
# command is killed (with its process group) after timeout_seconds.
statusline_refresh_if_stale() {
    local cache_file="$1" ttl="$2" lock_key="$3" lock_stale_after="$4"
    local timeout_seconds="$5" now="$6"
    shift 6
    statusline_cache_is_fresh "$cache_file" "$ttl" "$now" && return 0
    statusline_lock_acquire "$lock_key" "$lock_stale_after" "$now" || return 0
    mkdir -p "${cache_file%/*}"
    printf '%s\n' "$now" > "${cache_file}.timestamp"
    if perl -e '
            $timeout = shift;
            $pid = fork();
            exit 127 unless defined $pid;
            if ($pid == 0) {
                setpgrp(0, 0);
                exec @ARGV;
                exit 127;
            }
            $SIG{ALRM} = sub {
                kill "TERM", -$pid;
                select undef, undef, undef, 0.1;
                kill "KILL", -$pid;
                waitpid $pid, 0;
                exit 124;
            };
            alarm $timeout;
            waitpid $pid, 0;
            alarm 0;
            exit($? == -1 ? 127 : $? >> 8);
        ' "$timeout_seconds" "$@" > "${cache_file}.tmp" 2>/dev/null \
        && [ -s "${cache_file}.tmp" ]; then
        mv "${cache_file}.tmp" "$cache_file"
    else
        rm -f "${cache_file}.tmp"
    fi
    statusline_lock_release
}

# Liveness signal read by agent-usage-tracker's pollers for their
# watched-vs-idle cadence (see README.md's "agent-usage-tracker") - content
# doesn't matter, only mtime, so a plain overwrite is fine, no lock needed.
statusline_touch_heartbeat() {
    local provider="$1" now="$2"
    mkdir -p "$STATUSLINE_STATE_DIR/heartbeat"
    printf '%s\n' "$now" > "$STATUSLINE_STATE_DIR/heartbeat/$provider" 2>/dev/null || true
}

# statusline_advance_spin_index - a persisted counter, +1 mod 10 per render,
# so the spinner moves every render: `now % 10` freezes when refreshInterval
# is 10. No lock: a lost increment is invisible.
statusline_advance_spin_index() {
    local provider="$1" output_name="$2"
    local spin_dir="$STATUSLINE_STATE_DIR/spin" spin_file current next
    mkdir -p "$spin_dir"
    spin_file="$spin_dir/$provider"
    current=""
    [ -f "$spin_file" ] && IFS= read -r current < "$spin_file"
    case "$current" in
        ''|*[!0-9]*) current=0 ;;
    esac
    next=$(( (current + 1) % 10 ))
    printf '%s\n' "$next" > "$spin_file" 2>/dev/null || true
    printf -v "$output_name" '%s' "$next"
}

# statusline_overlay_freshest_quota <file>... - sets the caller's
# five_pct/five_reset/week_pct/week_reset (same implicit-variable convention
# as statusline_common_segments in format.sh) from whichever of the given
# quota files holds the newest observed_at; on a tie, the earliest argument
# wins. Missing or unreadable files never win, and with none the caller's
# values are left alone. File format, FS-separated: five_pct five_reset
# week_pct week_reset source observed_at, where source is X (a render's own
# stdin) or P (agent-usage-tracker's poller).
statusline_overlay_freshest_quota() {
    local file observed best="" best_observed=-1
    for file in "$@"; do
        [ -f "$file" ] || continue
        observed=""
        IFS="$STATUSLINE_FIELD_SEPARATOR" read -r _ _ _ _ _ observed < "$file"
        case "$observed" in ''|*[!0-9]*) continue ;; esac
        if [ "$observed" -gt "$best_observed" ]; then
            best="$file" best_observed="$observed"
        fi
    done
    [ -n "$best" ] || return 0
    IFS="$STATUSLINE_FIELD_SEPARATOR" read -r five_pct five_reset week_pct week_reset _ _ < "$best"
}

# The write path for a "latest known quota" file in the six-field format
# above. Compares on observed_at (epoch seconds the reading was actually
# true, NOT write time) and overwrites only if strictly newer, so whichever
# session has the genuinely freshest reading wins regardless of write order,
# and every open session converges on it within about one render cycle.
# No locking: a same-instant race could rarely clobber a fresher value with
# a slightly-less-fresh one, atomic mv still prevents a torn file, and the
# next render self-corrects. agent-usage-tracker writes its own file of the
# same format with the same rule.
statusline_write_quota_if_newer() {
    local quota_cache="$1" five_pct="$2" five_reset="$3" week_pct="$4" \
        week_reset="$5" source="$6" observed_at="$7"
    local existing_observed_at="" tmp
    mkdir -p "${quota_cache%/*}"
    if [ -f "$quota_cache" ]; then
        IFS="$STATUSLINE_FIELD_SEPARATOR" read -r _ _ _ _ _ existing_observed_at < "$quota_cache"
    fi
    if [ -n "$existing_observed_at" ] && [ "$observed_at" -le "$existing_observed_at" ] 2>/dev/null; then
        return 0
    fi
    tmp="${quota_cache}.tmp.$$-${RANDOM:-0}"
    printf '%s\n' \
        "${five_pct}${STATUSLINE_FIELD_SEPARATOR}${five_reset}${STATUSLINE_FIELD_SEPARATOR}${week_pct}${STATUSLINE_FIELD_SEPARATOR}${week_reset}${STATUSLINE_FIELD_SEPARATOR}${source}${STATUSLINE_FIELD_SEPARATOR}${observed_at}" \
        > "$tmp"
    mv "$tmp" "$quota_cache"
}

# statusline_transcript_observed_at <transcript_path> <output_name> - when
# a Claude session's rate_limits reading actually became true: the
# timestamp of the last *assistant* message in its transcript, since only
# an API response updates rate_limits. Not "now", and not just any entry:
# an idle session keeps re-sending a days-old reading while its transcript
# still gains bookkeeping entries. Sets the output to "" when no assistant message
# is found in the last 256 KB, or the transcript is missing - callers must
# then treat the reading as of unknown age, never as fresh.
#
# The last 256 KB is read with tail -c, so its first line is usually cut:
# each line is parsed on its own (fromjson?) and broken ones are skipped.
# The UTC timestamp is converted by plain calendar arithmetic (Howard
# Hinnant's days_from_civil), not jq's fromdateiso8601: jq 1.6 on macOS goes
# through the local timezone and returns an epoch one hour too late whenever
# that zone is in daylight-saving time. Only UTC timestamps ("Z" or
# "+00:00", optional fractional seconds) are accepted.
statusline_transcript_observed_at() {
    local transcript_path="$1" output_name="$2" result=""
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        result="$(tail -c 262144 "$transcript_path" 2>/dev/null | jq -R -r -n '
            def epoch:
                capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(\\.[0-9]+)?(Z|\\+00:00)$")
                | map_values(tonumber)
                | (if .mo <= 2 then .y - 1 else .y end) as $y
                | (($y / 400) | floor) as $era
                | ($y - $era * 400) as $yoe
                | (((153 * (if .mo > 2 then .mo - 3 else .mo + 9 end) + 2) / 5 | floor) + .d - 1) as $doy
                | ($yoe * 365 + (($yoe / 4) | floor) - (($yoe / 100) | floor) + $doy) as $doe
                | ($era * 146097 + $doe - 719468) * 86400 + .h * 3600 + .mi * 60 + .s;
            [inputs | fromjson? | select(type == "object" and .type == "assistant" and .timestamp != null) | .timestamp]
            | if length == 0 then empty else last end
            | epoch
        ' 2>/dev/null)"
    fi
    printf -v "$output_name" '%s' "$result"
}

# Sets STATUSLINE_HOSTNAME (read live: macOS renames the host, e.g. a "-1"
# suffix on a name clash) and STATUSLINE_HOST_COLOR (cached per hostname,
# from bootstrap-home's get_host_color, default 45).
statusline_read_host() {
    local color_file
    STATUSLINE_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
    color_file="$STATUSLINE_STATE_DIR/host-color/$STATUSLINE_HOSTNAME"
    if [ -s "$color_file" ]; then
        IFS= read -r STATUSLINE_HOST_COLOR < "$color_file"
        return
    fi
    STATUSLINE_HOST_COLOR="$("$HOME/opt/bootstrap-home/bin/get_host_color" \
        "$STATUSLINE_HOSTNAME" 2>/dev/null || printf '45')"
    mkdir -p "${color_file%/*}"
    printf '%s\n' "$STATUSLINE_HOST_COLOR" > "$color_file"
}
