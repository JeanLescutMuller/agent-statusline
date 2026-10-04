#!/bin/bash
# Shared lazy cache primitives for Claude and Codex statusline renderers.

STATUSLINE_RUNTIME_DIR="${STATUSLINE_RUNTIME_DIR:-$HOME/opt/agent-statusline}"
STATUSLINE_STATE_DIR="$STATUSLINE_RUNTIME_DIR/state"
STATUSLINE_LOCK_DIR="$STATUSLINE_RUNTIME_DIR/locks"
STATUSLINE_LOG_DIR="$STATUSLINE_RUNTIME_DIR/logs"
STATUSLINE_LOG_FILE="$STATUSLINE_LOG_DIR/statusline.log"
STATUSLINE_LOG_MAX_BYTES="${STATUSLINE_LOG_MAX_BYTES:-1048576}"
STATUSLINE_FIELD_SEPARATOR=$'\034'

statusline_cache_init() {
    [ -d "$STATUSLINE_STATE_DIR" ] && [ -d "$STATUSLINE_LOCK_DIR" ] \
        && [ -d "$STATUSLINE_LOG_DIR" ] && return
    mkdir -p "$STATUSLINE_STATE_DIR" "$STATUSLINE_LOCK_DIR" "$STATUSLINE_LOG_DIR"
}

# Log cache activity, not every render. Per-render logging would produce about
# 650k lines/day at 30 sessions and a four-second Codex refresh interval.
statusline_log_event() {
    local now="$1" event="$2" details="${3:-}" log_file="$STATUSLINE_LOG_FILE" size=0
    mkdir -p "$STATUSLINE_LOG_DIR"
    if [ -f "$log_file" ]; then
        size="$(stat -f %z "$log_file" 2>/dev/null \
            || stat -c %s "$log_file" 2>/dev/null \
            || printf '0')"
    fi
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge "$STATUSLINE_LOG_MAX_BYTES" ]; then
        mv "$log_file" "${log_file}.1" 2>/dev/null || true
    fi
    printf '%s event=%s%s%s\n' "$now" "$event" "${details:+ }" "$details" \
        >> "$log_file" 2>/dev/null || true
}

statusline_cache_is_fresh() {
    local cache_file="$1" ttl="$2" now="$3" timestamp=""
    [ -f "$cache_file" ] || return 1
    [ -f "${cache_file}.timestamp" ] || return 1
    IFS= read -r timestamp < "${cache_file}.timestamp"
    case "$timestamp" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ $((now - timestamp)) -lt "$ttl" ]
}

statusline_lock_acquire() {
    local lock_key="$1" stale_after="$2" now="$3"
    local lock_path="$STATUSLINE_LOCK_DIR/${lock_key}.lock"
    local lock_timestamp="" quarantine=""

    STATUSLINE_LOCK_TOKEN="$$-${RANDOM:-0}-$now"
    STATUSLINE_LOCK_PATH="$lock_path"

    if ! mkdir "$lock_path" 2>/dev/null; then
        [ -f "$lock_path/timestamp" ] && IFS= read -r lock_timestamp < "$lock_path/timestamp"
        case "$lock_timestamp" in
            ''|*[!0-9]*) lock_timestamp=0 ;;
        esac
        [ $((now - lock_timestamp)) -ge "$stale_after" ] || return 1

        quarantine="${lock_path}.stale.$$-${RANDOM:-0}"
        mv "$lock_path" "$quarantine" 2>/dev/null || return 1
        rm -f "$quarantine/owner" "$quarantine/timestamp"
        rmdir "$quarantine" 2>/dev/null || true
        mkdir "$lock_path" 2>/dev/null || return 1
    fi

    printf '%s\n' "$STATUSLINE_LOCK_TOKEN" > "$lock_path/owner"
    printf '%s\n' "$now" > "$lock_path/timestamp"
}

statusline_lock_release() {
    local owner=""
    [ -n "${STATUSLINE_LOCK_PATH:-}" ] || return
    [ -f "$STATUSLINE_LOCK_PATH/owner" ] && IFS= read -r owner < "$STATUSLINE_LOCK_PATH/owner"
    [ "$owner" = "${STATUSLINE_LOCK_TOKEN:-}" ] || return
    rm -f "$STATUSLINE_LOCK_PATH/owner" "$STATUSLINE_LOCK_PATH/timestamp"
    rmdir "$STATUSLINE_LOCK_PATH" 2>/dev/null || true
    STATUSLINE_LOCK_PATH=""
    STATUSLINE_LOCK_TOKEN=""
}

statusline_refresh_if_stale() {
    local cache_file="$1" ttl="$2" lock_key="$3" lock_stale_after="$4"
    local timeout_seconds="$5" now="$6"
    shift 6
    local cache_dir tmp error_tmp timestamp_tmp attempted_tmp attempted_at=""
    local cache_timestamp="" stale_age="unknown" refresh_exit=0 error="" lock_acquired=false

    statusline_cache_is_fresh "$cache_file" "$ttl" "$now" && return 0
    if [ -f "${cache_file}.attempted" ]; then
        IFS= read -r attempted_at < "${cache_file}.attempted"
        case "$attempted_at" in
            ''|*[!0-9]*) attempted_at=0 ;;
        esac
        if [ $((now - attempted_at)) -lt "$ttl" ]; then
            [ -d "$STATUSLINE_LOCK_DIR/${lock_key}.lock" ] || return 0
            statusline_lock_acquire "$lock_key" "$lock_stale_after" "$now" || return 0
            lock_acquired=true
        fi
    fi
    [ "$lock_acquired" = true ] \
        || statusline_lock_acquire "$lock_key" "$lock_stale_after" "$now" \
        || return 0

    cache_dir="${cache_file%/*}"
    mkdir -p "$cache_dir"
    rm -f "${cache_file}.tmp."* "${cache_file}.timestamp.tmp."* \
        "${cache_file}.attempted.tmp."*
    tmp="${cache_file}.tmp.$$-${RANDOM:-0}"
    error_tmp="${cache_file}.error.tmp.$$-${RANDOM:-0}"
    timestamp_tmp="${cache_file}.timestamp.tmp.$$-${RANDOM:-0}"
    attempted_tmp="${cache_file}.attempted.tmp.$$-${RANDOM:-0}"
    printf '%s\n' "$now" > "$attempted_tmp"
    mv "$attempted_tmp" "${cache_file}.attempted" 2>/dev/null \
        || printf '%s\n' "$now" > "${cache_file}.attempted"

    if command -v perl >/dev/null 2>&1 \
        && perl -e '
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
        ' "$timeout_seconds" "$@" > "$tmp" 2> "$error_tmp"; then
        refresh_exit=0
    else
        refresh_exit=$?
    fi

    if [ "$refresh_exit" -eq 0 ] && [ -s "$tmp" ]; then
        mv "$tmp" "$cache_file"
        printf '%s\n' "$now" > "$timestamp_tmp"
        mv "$timestamp_tmp" "${cache_file}.timestamp"
        rm -f "${cache_file}.attempted"
        statusline_log_event "$now" refresh_success "key=$lock_key"
    else
        [ "$refresh_exit" -eq 0 ] && refresh_exit=65
        if [ -f "${cache_file}.timestamp" ]; then
            IFS= read -r cache_timestamp < "${cache_file}.timestamp"
            [[ "$cache_timestamp" =~ ^[0-9]+$ ]] && stale_age="$((now - cache_timestamp))s"
        fi
        if [ -s "$error_tmp" ]; then
            error="$(LC_ALL=C tr '\n\t' '  ' < "$error_tmp" | cut -c 1-300)"
        fi
        statusline_log_event "$now" refresh_failed \
            "key=$lock_key exit=$refresh_exit stale_age=${stale_age}${error:+ error=$error}"
        rm -f "$tmp" "$timestamp_tmp"
    fi
    rm -f "$error_tmp"

    statusline_lock_release
}

statusline_write_values_if_stale() {
    local cache_file="$1" ttl="$2" lock_key="$3" lock_stale_after="$4" now="$5"
    shift 5
    local cache_dir tmp timestamp_tmp value

    statusline_cache_is_fresh "$cache_file" "$ttl" "$now" && return 0
    statusline_lock_acquire "$lock_key" "$lock_stale_after" "$now" || return 0

    cache_dir="${cache_file%/*}"
    mkdir -p "$cache_dir"
    tmp="${cache_file}.tmp.$$-${RANDOM:-0}"
    timestamp_tmp="${cache_file}.timestamp.tmp.$$-${RANDOM:-0}"
    : > "$tmp"
    for value in "$@"; do
        [ -s "$tmp" ] && printf '%s' "$STATUSLINE_FIELD_SEPARATOR" >> "$tmp"
        printf '%s' "$value" >> "$tmp"
    done
    printf '\n' >> "$tmp"
    mv "$tmp" "$cache_file"
    printf '%s\n' "$now" > "$timestamp_tmp"
    mv "$timestamp_tmp" "${cache_file}.timestamp"
    statusline_log_event "$now" payload_cache_write "key=$lock_key"
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

# Overlays cached FS-separated quota values onto the caller's own
# five_pct/five_reset/week_pct/week_reset (same implicit-variable
# convention as statusline_common_segments in format.sh) - only overlays
# fields the cache has a non-empty value for, so a not-yet-populated cache
# can't blank out a caller's already-live value. Field 5 is an origin tag
# (X = a statusline render's own stdin, P = agent-usage-tracker's poller),
# field 6 the observed_at epoch the writers compare on - neither is
# displayed, hence the throwaway `_`s.
statusline_overlay_quota_cache() {
    local quota_cache="$1"
    local cached_five_pct cached_five_reset cached_week_pct cached_week_reset _
    [ -f "$quota_cache" ] || return
    IFS="$STATUSLINE_FIELD_SEPARATOR" read -r cached_five_pct cached_five_reset \
        cached_week_pct cached_week_reset _ _ < "$quota_cache"
    [ -n "$cached_five_pct" ] && five_pct="$cached_five_pct"
    [ -n "$cached_five_reset" ] && five_reset="$cached_five_reset"
    [ -n "$cached_week_pct" ] && week_pct="$cached_week_pct"
    [ -n "$cached_week_reset" ] && week_reset="$cached_week_reset"
}

# statusline_overlay_freshest_quota <file>... - overlays whichever of the
# given six-field quota files holds the newest observed_at (field 6); on a
# tie, the earliest argument wins. Missing or unreadable files never win.
# Used for Claude: this repo's own state/quota/claude against
# agent-usage-tracker's, so neither can freeze the display on a stale
# reading - the fresher one is shown, whoever wrote it.
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
    [ -n "$best" ] && statusline_overlay_quota_cache "$best"
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

statusline_read_static() {
    local hostname_file="$STATUSLINE_STATE_DIR/static/hostname"
    local color_file="$STATUSLINE_STATE_DIR/static/host-color"

    if [ ! -s "$hostname_file" ] || [ ! -s "$color_file" ]; then
        mkdir -p "$STATUSLINE_STATE_DIR/static"
        STATUSLINE_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
        STATUSLINE_HOST_COLOR="$("$HOME/opt/bootstrap-home/bin/get_host_color" \
            "$STATUSLINE_HOSTNAME" 2>/dev/null || printf '45')"
        printf '%s\n' "$STATUSLINE_HOSTNAME" > "${hostname_file}.tmp.$$"
        mv "${hostname_file}.tmp.$$" "$hostname_file"
        printf '%s\n' "$STATUSLINE_HOST_COLOR" > "${color_file}.tmp.$$"
        mv "${color_file}.tmp.$$" "$color_file"
        return
    fi
    IFS= read -r STATUSLINE_HOSTNAME < "$hostname_file"
    IFS= read -r STATUSLINE_HOST_COLOR < "$color_file"
}

statusline_git_cache_paths() {
    # Two `local`s: one would expand ${cwd} before assigning it.
    local cwd="$1"
    local cache_dir="$STATUSLINE_STATE_DIR/git/cwd${cwd}"

    STATUSLINE_GIT_ROOT="$cwd"
    STATUSLINE_GIT_KEY="cwd${cwd//\//-}"
    STATUSLINE_GIT_LOCAL_CACHE="$cache_dir/local"
    STATUSLINE_GIT_REMOTE_CACHE="$cache_dir/remote"
}
