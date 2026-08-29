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
    local now="$1" event="$2" details="${3:-}" size=0
    mkdir -p "$STATUSLINE_LOG_DIR"
    if [ -f "$STATUSLINE_LOG_FILE" ]; then
        size="$(stat -f %z "$STATUSLINE_LOG_FILE" 2>/dev/null \
            || stat -c %s "$STATUSLINE_LOG_FILE" 2>/dev/null \
            || printf '0')"
    fi
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge "$STATUSLINE_LOG_MAX_BYTES" ]; then
        mv "$STATUSLINE_LOG_FILE" "${STATUSLINE_LOG_FILE}.1" 2>/dev/null || true
    fi
    printf '%s event=%s%s%s\n' "$now" "$event" "${details:+ }" "$details" \
        >> "$STATUSLINE_LOG_FILE" 2>/dev/null || true
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
    local cwd="$1" cache_dir="$STATUSLINE_STATE_DIR/git/cwd${cwd}"

    STATUSLINE_GIT_ROOT="$cwd"
    STATUSLINE_GIT_KEY="cwd${cwd//\//-}"
    STATUSLINE_GIT_LOCAL_CACHE="$cache_dir/local"
    STATUSLINE_GIT_REMOTE_CACHE="$cache_dir/remote"
}
