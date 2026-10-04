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
