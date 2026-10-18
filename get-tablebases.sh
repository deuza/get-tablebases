#!/bin/sh
# shellcheck disable=SC3043
#
# get-tablebases.sh - Downloads and verifies the Gaviota or Syzygy chess endgame
# tablebases from the Lichess mirror (https://tablebase.lichess.ovh/tables/standard/).
#
# Linux and macOS counterpart of get-tablebases.ps1 (Windows): same menu, same
# questions, same messages, same exit codes, same layout, and the same lock and
# state files next to the script. Written in POSIX sh: it runs with dash, bash
# (including the bash 3.2 that macOS ships as /bin/sh) and busybox sh.
#
# Interactive and resumable downloader. One run handles ONE set of tables:
#
#     Gaviota            3-4-5 pieces, compressed (.gtb.cp4)
#     Syzygy 3-4-5       WDL + DTZ, up to 5 pieces
#     Syzygy 3-4-5-6     WDL + DTZ, up to 6 pieces
#     Syzygy 3-4-5-6-7   WDL + DTZ, up to 7 pieces (about 17 TiB)
#
# and ONE action: download the set (verification offered at the end), or
# verify it only.
#
# Resulting layout below the destination (--root):
#
#     Gaviota/   *.gtb.cp4 + Gaviota.cp4.md5
#     Syzygy/    *.rtbw + *.rtbz + exactly one checksum file
#                (3-4-5.md5, 3-4-5-6.md5 or 3-4-5-6-7.md5)
#
# File lists, sizes and checksums are read from the server at every run:
# the sizes displayed by the menu are the real remote ones.
#
# Robustness, in short (README.md has the details):
#   * a file is complete when its local size equals the remote size;
#     downloads go to <name>.part, are flushed to disk, then renamed;
#   * after any failure the script restarts curl, which resumes from the
#     last byte received (curl's own --retry would throw those bytes away);
#   * every file that was partial when a job started is MD5-checked once
#     complete; free space and FAT32 limits are checked before downloading;
#   * <script>.lock (a directory next to the script) forbids concurrent runs;
#     <script>.state remembers the job until it succeeds, so an interrupted
#     run can be resumed, purged and restarted, or abandoned.
#
# Options:
#     --root DIR    Destination directory; Gaviota/ and Syzygy/ are created
#                   below it. Default: the directory of the script.
#     --curl PATH   curl executable. Default: the curl found in PATH.
#     -h, --help    This summary.
#
# Requirements: curl, awk, df, mount, ps, sync, sed, sort, and one of md5sum,
# md5 or openssl. All of them ship with Debian, every common Linux and macOS.
#
# Version 1.0.0
# Exit codes: 0 success (or the user quit), 1 error or unfinished job,
# 2 another instance is running, 3 the stale lock of an interrupted run was
# kept (the user declined to remove it).

LC_ALL=C
export LC_ALL

# ------------------------------------------------------------------ Settings

SCRIPT_VERSION='1.0.0'
STATE_FORMAT=1              # bump if the layout of the .state file changes
BASE_URL='https://tablebase.lichess.ovh/tables/standard'
USER_AGENT="get-tablebases.sh/$SCRIPT_VERSION"
MAX_STALLED=6               # curl runs in a row without any progress before giving up on a file
CHECKPOINT_SEC=5            # how often (seconds) a verification saves its progress
BG_MD5_BYTES=67108864       # files of 64 MiB or more are hashed in the background, with a live line

MENU_KEYS='gaviota 345 3456 34567'   # the four sets of the menu, in order
SYZYGY_KEYS='345 3456 34567'         # smallest first; a 3-4-5-6-7.md5 also covers 3-4-5-6 and 3-4-5

TAB=$(printf '\t')

# The four sets. RemoteDirs: top-level directories of the server making up the set.
# MaxPieces: used to filter checksum files.
set_label()     { case $1 in gaviota) printf 'Gaviota';; 345) printf 'Syzygy 3-4-5';;
                           3456) printf 'Syzygy 3-4-5-6';; 34567) printf 'Syzygy 3-4-5-6-7';; esac; }
set_kind()      { case $1 in gaviota) printf 'Gaviota';; *) printf 'Syzygy';; esac; }
set_subdir()    { set_kind "$1"; }
set_maxpieces() { case $1 in gaviota) printf '5';; 345) printf '5';; 3456) printf '6';; 34567) printf '7';; esac; }
set_md5name()   { case $1 in gaviota) printf 'Gaviota.cp4.md5';; 345) printf '3-4-5.md5';;
                           3456) printf '3-4-5-6.md5';; 34567) printf '3-4-5-6-7.md5';; esac; }
set_dirs()      { case $1 in gaviota) printf 'Gaviota';; 345) printf '3-4-5-wdl 3-4-5-dtz';;
                           3456) printf '3-4-5-wdl 3-4-5-dtz 6-wdl 6-dtz';;
                           34567) printf '3-4-5-wdl 3-4-5-dtz 6-wdl 6-dtz 7';; esac; }
set_known()     { case $1 in gaviota|345|3456|34567) return 0;; *) return 1;; esac; }

# Runtime state, shared by the functions below.
PLAIN=0                     # output redirected: no in-place progress line
STATUS_ACTIVE=0             # an in-place progress line is on screen
LOCK_HELD=0                 # this process owns the lock directory
CURL_PATH=''                # resolved curl executable, empty when curl is missing
BG_PID=''                   # wrapper of the background command (curl or md5), if any
TMP_DIR=''                  # scratch directory, removed on exit
CATALOG=0                   # 1 when the server catalog was read
VERIFY_ACTIVE=0             # a verification is running: Ctrl+C saves its checkpoint
ROOT_ARG=''                 # --root as given
ROOT_GIVEN=0
CURL_ARG=''                 # --curl as given
STARTED_AT=$(date '+%Y-%m-%dT%H:%M:%S')

# awk helpers shared by every formatting call (binary sizes, compact durations).
AWK_LIB='
function fmt_size(b,    u, i, n) {
    n = split("B KiB MiB GiB TiB PiB", u, " ")
    i = 1
    while (b >= 1024 && i < n) { b = b / 1024; i++ }
    if (i == 1) return sprintf("%.0f %s", b, u[i])
    return sprintf("%.2f %s", b, u[i])
}
function fmt_duration(s,    d, h, m) {
    if (s == "" || s < 0) return "?"
    s = int(s + 0.5)
    if (s >= 86400) { d = int(s / 86400); h = int((s % 86400) / 3600); return sprintf("%dd %02dh", d, h) }
    if (s >= 3600) { h = int(s / 3600); m = int((s % 3600) / 60); return sprintf("%dh %02dm", h, m) }
    if (s >= 60) { m = int(s / 60); return sprintf("%dm %02ds", m, s % 60) }
    return sprintf("%ds", s)
}
'

# ------------------------------------------------------------------ Console helpers

C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_CYAN=''; C_RESET=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
    C_GREEN=$(printf '\033[32m'); C_YELLOW=$(printf '\033[33m'); C_RED=$(printf '\033[31m')
    C_GRAY=$(printf '\033[90m'); C_CYAN=$(printf '\033[36m'); C_RESET=$(printf '\033[0m')
fi

fmt_size()     { awk -v b="$1" "$AWK_LIB"'BEGIN { print fmt_size(b) }'; }
fmt_duration() { awk -v s="$1" "$AWK_LIB"'BEGIN { print fmt_duration(s) }'; }
fmt_stamp()    { printf '%s' "$1" | tr 'T' ' '; }       # "2026-10-18T13:42:46" -> "2026-10-18 13:42:46"
count_lines()  { awk 'END { print NR + 0 }' "$1"; }
last_line()    { awk 'NF { l = $0 } END { gsub(/^[ \t\r]+|[ \t\r]+$/, "", l); print l }' "$1"; }

console_width() {
    # Console width, with a sane fallback when there is no real console.
    local w
    w=$(tput cols 2>/dev/null)
    case $w in ''|*[!0-9]*) w=80;; esac
    [ "$w" -ge 40 ] || w=80
    printf '%s' "$w"
}

clear_status() {
    # Erases the in-place progress line before a regular message is printed.
    local w
    if [ "$STATUS_ACTIVE" = 1 ]; then
        w=$(console_width)
        printf "\r%-$((w - 1))s\r" ''
        STATUS_ACTIVE=0
    fi
}

status() {
    # One self-overwriting progress line (skipped when the output is redirected to a file).
    local w line
    [ "$PLAIN" = 1 ] && return 0
    w=$(console_width)
    line=$(printf '%s' "$1" | awk -v w="$((w - 1))" '{ printf "%-" w "s", substr($0, 1, w) }')
    printf '\r%s' "$line"
    STATUS_ACTIVE=1
}

msg() {
    # Regular message, colored by level: info (default), ok, warn, error, note, title.
    clear_status
    case $1 in
        ok)    printf '%s%s%s\n' "$C_GREEN" "$2" "$C_RESET" ;;
        warn)  printf '%sWARNING: %s%s\n' "$C_YELLOW" "$2" "$C_RESET" ;;
        error) printf '%sERROR: %s%s\n' "$C_RED" "$2" "$C_RESET" ;;
        note)  printf '%s%s%s\n' "$C_GRAY" "$2" "$C_RESET" ;;
        title) printf '%s%s%s\n' "$C_CYAN" "$2" "$C_RESET" ;;
        *)     printf '%s\n' "$2" ;;
    esac
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
trim()  { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

read_choice() {
    # Asks until one of the allowed answers ($2, space separated) is typed (case-insensitive).
    # ANSWER gets it in upper case, or $3 on an empty line. Returns 1 when the input is closed.
    local prompt allowed default ans item
    prompt=$1; allowed=$2; default=$3
    while :; do
        clear_status
        printf '%s: ' "$prompt"
        if ! IFS= read -r ans; then printf '\n'; ANSWER=''; return 1; fi
        ans=$(upper "$(trim "$ans")")
        if [ -z "$ans" ] && [ -n "$default" ]; then ANSWER=$(upper "$default"); return 0; fi
        for item in $allowed; do
            if [ "$ans" = "$(upper "$item")" ]; then ANSWER=$(upper "$item"); return 0; fi
        done
        msg warn "Please answer one of: $(printf '%s' "$allowed" | sed 's/ /, /g')"
    done
}

read_yesno() {
    # Yes/no question; $2 is the default (Y or N). An empty answer selects the default,
    # a closed input means "no". Returns 0 for yes.
    local hint
    if [ "$2" = Y ]; then hint='[Y/n]'; else hint='[y/N]'; fi
    read_choice "$1 $hint" 'Y N YES NO' "$2" || return 1
    case $ANSWER in Y|YES) return 0;; *) return 1;; esac
}

read_confirmation() {
    # Destructive or huge operations: the user must type a word ($2), in capitals.
    local ans
    clear_status
    printf '%s Type %s to confirm (anything else cancels): ' "$1" "$2"
    if ! IFS= read -r ans; then printf '\n'; return 1; fi
    [ "$(trim "$ans")" = "$2" ]
}

# ------------------------------------------------------------------ Paths, files and volumes

resolve_root() {
    # Absolute destination path (may not exist yet), without trailing slash.
    local p
    p=$1
    [ -n "$p" ] || p=$PWD
    case $p in /*) ;; *) p="$PWD/$p";; esac
    while :; do
        case $p in
            */./*) p=$(printf '%s' "$p" | sed 's#/\./#/#');;
            *//*)  p=$(printf '%s' "$p" | sed 's#//#/#');;
            */.)   p=${p%/.};;
            ?*/)   p=${p%/};;
            *)     break;;
        esac
    done
    [ -n "$p" ] || p=/
    printf '%s' "$p"
}

existing_ancestor() {
    # Nearest existing directory of a path (the destination may not be created yet).
    local p parent
    p=$1
    while [ -n "$p" ] && [ ! -d "$p" ]; do
        parent=$(dirname "$p")
        [ "$parent" = "$p" ] && break
        p=$parent
    done
    printf '%s' "$p"
}

detect_tools() {
    # stat flavor (GNU: -c, BSD: -f), MD5 tool, fractional sleep: detected once by behaviour,
    # so a GNU userland installed on macOS (Homebrew coreutils in PATH) works as well.
    if stat -c %s / >/dev/null 2>&1; then STAT_FLAVOR=gnu
    elif stat -f %z / >/dev/null 2>&1; then STAT_FLAVOR=bsd
    else STAT_FLAVOR='ls'; fi
    if command -v md5sum >/dev/null 2>&1; then MD5_FLAVOR=md5sum; MD5_BIN=$(command -v md5sum)
    elif command -v md5 >/dev/null 2>&1; then MD5_FLAVOR=md5; MD5_BIN=$(command -v md5)
    elif command -v openssl >/dev/null 2>&1; then MD5_FLAVOR=openssl; MD5_BIN=$(command -v openssl)
    else MD5_FLAVOR=''; MD5_BIN=''; fi
    # Polling interval while curl or md5 runs in the background; the progress line is
    # refreshed once per second whatever the interval.
    if sleep 0.2 2>/dev/null; then POLL=0.2; POLL_PER_SEC=5; else POLL=1; POLL_PER_SEC=1; fi
}

file_size() {
    # Current size of a file in bytes, 0 when it does not exist.
    local s
    [ -e "$1" ] || { printf '0'; return 0; }
    # shellcheck disable=SC2012
    case $STAT_FLAVOR in
        gnu) s=$(stat -c %s "$1" 2>/dev/null) ;;
        bsd) s=$(stat -f %z "$1" 2>/dev/null) ;;
        *)   s=$(ls -lnd "$1" 2>/dev/null | awk '{ print $5 }') ;;
    esac
    case $s in ''|*[!0-9]*) s=0;; esac
    printf '%s' "$s"
}

local_table() {
    # "size<TAB>name" for every entry of a directory (one process for thousands of files).
    [ -d "$1" ] || return 0
    (
        cd "$1" || exit 0
        set -- ./*
        [ -e "$1" ] || exit 0
        # shellcheck disable=SC2012
        case $STAT_FLAVOR in
            gnu) stat -c "%s$TAB%n" "$@" 2>/dev/null ;;
            bsd) stat -f "%z$TAB%N" "$@" 2>/dev/null ;;
            *)   ls -lnd "$@" 2>/dev/null | awk -v T="$TAB" 'NF >= 9 { print $5 T $9 }' ;;
        esac | awk -F "$TAB" -v T="$TAB" '{ n = $2; sub(/^\.\//, "", n); print $1 T n }'
    )
}

sync_file() {
    # Forces the data of a file out of the OS cache: coreutils fsync the file, BSD sync
    # flushes everything. A power cut can otherwise leave a renamed file whose last blocks
    # were never written.
    sync "$1" 2>/dev/null || sync
}

volume_info() {
    # Free space (bytes) and file system name of the volume holding an existing directory,
    # in VOL_FREE (-1 when unknown) and VOL_FS ('' when unknown).
    local dev
    VOL_FREE=-1; VOL_FS=''
    VOL_FREE=$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { printf "%.0f", $4 * 1024 }')
    if [ -z "$VOL_FREE" ]; then
        VOL_FREE=-1
        msg warn "Cannot read the free space of $1: df failed"
    fi
    if [ "$STAT_FLAVOR" = gnu ]; then
        VOL_FS=$(stat -f -c %T "$1" 2>/dev/null)
    fi
    if [ -z "$VOL_FS" ]; then
        dev=$(df -P "$1" 2>/dev/null | awk 'NR == 2 { print $1 }')
        [ -n "$dev" ] && VOL_FS=$(mount 2>/dev/null | awk -v d="$dev" '
            $1 == d { s = $0
                      if (match(s, / type [^ ]+/)) { s = substr(s, RSTART + 6, RLENGTH - 6) }     # Linux: "... type ext4 (rw,...)"
                      else { sub(/^[^(]*\(/, "", s); sub(/[,)].*$/, "", s) }                     # BSD/macOS: "... (apfs, local, ...)"
                      print s; exit }')
    fi
}

free_space_text() {
    # "1.23 TiB (apfs)" for the menu header, '' when unknown.
    local existing text
    existing=$(existing_ancestor "$1")
    [ -n "$existing" ] || return 0
    volume_info "$existing"
    [ "$VOL_FREE" -ge 0 ] || return 0
    text=$(fmt_size "$VOL_FREE")
    [ -n "$VOL_FS" ] && text="$text ($VOL_FS)"
    printf '%s' "$text"
}

is_fat() {
    # File system names of FAT volumes, as reported by Linux (stat -f) and macOS (mount).
    case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
        msdos|vfat|fat|fat12|fat16|fat32) return 0;;
        *) return 1;;
    esac
}

# ------------------------------------------------------------------ Background commands

bg_run() {
    # Runs a command in the background through a small wrapper: $1 receives the exit code when
    # the command ends (that file is the completion signal: a finished child only becomes a
    # zombie, so kill -0 cannot tell), $2 and $3 get its stdout and stderr. A TERM sent to the
    # wrapper (bg_kill) is passed on to the command, which the wrapper then reaps.
    local rc out err
    rc=$1; out=$2; err=$3; shift 3
    rm -f "$rc"
    (
        "$@" > "$out" 2> "$err" &
        c=$!
        trap 'kill "$c" 2>/dev/null' TERM
        wait "$c"; r=$?
        while kill -0 "$c" 2>/dev/null; do wait "$c"; r=$?; done   # wait interrupted by the trap
        printf '%s' "$r" > "$rc"
    ) &
    BG_PID=$!
}

bg_wait() {
    # Reaps the wrapper once the exit code file exists.
    wait "$BG_PID" 2>/dev/null
    BG_PID=''
}

bg_kill() {
    # Never leave a curl or md5 behind (Ctrl+C, error): it would keep its file busy.
    [ -n "$BG_PID" ] || return 0
    kill "$BG_PID" 2>/dev/null
    wait "$BG_PID" 2>/dev/null
    BG_PID=''
}

# ------------------------------------------------------------------ Lock and job state

process_alive() {
    # Is PID $1 a live process running this script (invoked as $2)? ps shows its command line,
    # which guards against a reused PID after a reboot; kill -0 is the fallback when ps cannot.
    local args
    case $1 in ''|*[!0-9]*) return 1;; esac
    if args=$(ps -p "$1" -o args= 2>/dev/null) && [ -n "$args" ]; then
        case $args in *"$2"*|*get-tablebases*) return 0;; *) return 1;; esac
    fi
    kill -0 "$1" 2>/dev/null
}

read_lock_info() {
    # Content of the lock's info file into LI_*; LI_OK=1 when it could be read.
    local f
    LI_OK=0; LI_PID=''; LI_HOST=''; LI_STARTED=''; LI_JOB=''; LI_SCRIPT=''
    f=$LOCK_PATH/info
    [ -f "$f" ] || return 0
    LI_PID=$(sed -n 's/^Pid=//p' "$f" | head -n 1)
    LI_HOST=$(sed -n 's/^Host=//p' "$f" | head -n 1)
    LI_STARTED=$(sed -n 's/^Started=//p' "$f" | head -n 1)
    LI_JOB=$(sed -n 's/^Job=//p' "$f" | head -n 1)
    LI_SCRIPT=$(sed -n 's/^Script=//p' "$f" | head -n 1)
    [ -n "$LI_PID" ] && LI_OK=1
}

format_lock_info() {
    # One line describing the owner of a lock.
    if [ "$LI_OK" != 1 ]; then printf '(no details: the lock file is empty or unreadable)'; return 0; fi
    printf 'PID %s on %s, started %s, job: %s' "$LI_PID" "$LI_HOST" "$(fmt_stamp "$LI_STARTED")" "$LI_JOB"
}

write_lock_info() {
    # Describes this run inside the lock (shown to a second instance).
    local tmp
    [ "$LOCK_HELD" = 1 ] || return 0
    tmp=$LOCK_PATH/info.tmp
    printf 'Pid=%s\nHost=%s\nUser=%s\nStarted=%s\nJob=%s\nScript=%s\n' \
        "$$" "$(hostname 2>/dev/null)" "$(id -un 2>/dev/null)" "$STARTED_AT" "$1" "$SCRIPT_PATH" > "$tmp" &&
        mv -f "$tmp" "$LOCK_PATH/info"
}

lock_instance() {
    # The lock is a directory: mkdir is atomic everywhere. A live holder is a process of this
    # host, still running the script, whose PID is recorded inside. A lock left by a dead
    # process (reboot, power cut, kill -9) is removed only if the user says so.
    # Returns 0 (acquired), 2 (another instance is running), 3 (stale lock kept) or 1 (failure).
    local attempt alive owner
    attempt=0
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        if mkdir "$LOCK_PATH" 2>/dev/null; then
            LOCK_HELD=1
            write_lock_info 'menu'
            return 0
        fi
        [ -e "$LOCK_PATH" ] || continue               # released and deleted meanwhile: try again
        read_lock_info
        alive=0
        if [ "$LI_OK" = 1 ] && [ "$LI_HOST" = "$(hostname 2>/dev/null)" ] &&
           process_alive "$LI_PID" "$(basename "${LI_SCRIPT:-$SCRIPT_PATH}")"; then
            alive=1
        fi
        owner=$(format_lock_info)
        if [ "$alive" = 1 ]; then
            msg error 'Another instance of this script is running:'
            msg info "  $owner"
            return 2
        fi
        msg warn 'A previous run was interrupted (reboot, power cut, killed process...):'
        msg info "  $owner"
        msg info '  No running process holds its lock any more.'
        # Explicit acknowledgement; "no", an empty answer or a closed input keep the lock.
        if ! read_yesno 'Remove this stale lock and continue?' N; then
            msg info "Lock kept: $LOCK_PATH"
            return 3
        fi
        rm -rf "$LOCK_PATH" 2>/dev/null && msg note 'Stale lock removed.'
    done
    msg error "Could not acquire the lock file $LOCK_PATH"
    return 1
}

unlock_instance() {
    # Normal end, error or Ctrl+C: the lock disappears, the job state stays.
    if [ "$LOCK_HELD" = 1 ]; then
        rm -rf "$LOCK_PATH" 2>/dev/null
        LOCK_HELD=0
    fi
}

state_value() { sed -n "s/^$1=//p" "$STATE_PATH" | head -n 1; }

init_job_state() {
    # A new job description (not saved yet): action ($1: Download or Verify), set ($2), root ($3).
    JOB_ACTION=$1; JOB_SET=$2; JOB_ROOT=$3
    JOB_STARTED=$(date '+%Y-%m-%dT%H:%M:%S')
    JOB_SOURCE=''                   # verification: where the expected checksums came from
    JOB_OK_FILE=''                  # verification checkpoint: "size name" per validated file
}

read_job_state() {
    # The unfinished job into JOB_*, return 0; return 1 when there is none. An unreadable
    # state file is reported and ignored.
    local reason
    [ -f "$STATE_PATH" ] || return 1
    JOB_ACTION=$(state_value Action); JOB_SET=$(state_value Set); JOB_ROOT=$(state_value Root)
    JOB_STARTED=$(state_value Started); JOB_SOURCE=$(state_value VerifySource)
    reason=''
    [ "$(state_value Format)" = "$STATE_FORMAT" ] || reason='unknown format'
    set_known "$JOB_SET" || reason='unknown set'
    case $JOB_ACTION in Download|Verify) ;; *) reason='unknown action';; esac
    [ -n "$JOB_ROOT" ] || reason='no destination'
    if [ -n "$reason" ]; then
        msg warn "Ignoring the unreadable job state file $STATE_PATH ($reason)."
        return 1
    fi
    JOB_OK_FILE=$TMP_DIR/ok.list
    sed -n 's/^ok //p' "$STATE_PATH" > "$JOB_OK_FILE"
    return 0
}

save_job_state() {
    # Atomic write: a crash in the middle leaves either the old or the new state, never a mix.
    local tmp
    tmp=$STATE_PATH.tmp
    {
        printf 'Format=%s\nScriptVersion=%s\nAction=%s\nSet=%s\nRoot=%s\nStarted=%s\n' \
            "$STATE_FORMAT" "$SCRIPT_VERSION" "$JOB_ACTION" "$JOB_SET" "$JOB_ROOT" "$JOB_STARTED"
        [ -n "$JOB_SOURCE" ] && printf 'VerifySource=%s\n' "$JOB_SOURCE"
        [ -n "$JOB_OK_FILE" ] && [ -f "$JOB_OK_FILE" ] && sed 's/^/ok /' "$JOB_OK_FILE"
        :
    } > "$tmp" && sync_file "$tmp" && mv -f "$tmp" "$STATE_PATH"
}

clear_job_state() {
    # The job succeeded (or was abandoned): nothing to resume any more.
    rm -f "$STATE_PATH" "$STATE_PATH.tmp"
}

# ------------------------------------------------------------------ curl

resolve_curl() {
    # Full path of the curl executable, or '' when it is missing.
    local name
    name=${1:-curl}
    command -v "$name" 2>/dev/null || :
}

curl_version() {
    # "8.13.0" for the banner (useful in bug reports).
    local v
    v=$("$CURL_PATH" --version 2>/dev/null | awk 'NR == 1 && $1 == "curl" { print $2 }')
    printf '%s' "${v:-unknown version}"
}

run_curl() {
    # Runs curl to completion in the foreground (small files); CURL_CODE and CURL_ERROR
    # (last meaningful line of its stderr) describe the result.
    local errf
    errf=$TMP_DIR/curl.err
    "$CURL_PATH" --stderr "$errf" "$@"
    CURL_CODE=$?
    CURL_ERROR=$(last_line "$errf")
    rm -f "$errf"
}

remote_text() {
    # Downloads a small text file (file lists, checksums) into $2. On failure, REMOTE_ERROR.
    run_curl -sS -f -L -A "$USER_AGENT" --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 3 \
        -o "$2" "$1"
    if [ "$CURL_CODE" -ne 0 ]; then
        REMOTE_ERROR="$1: curl exit $CURL_CODE ($CURL_ERROR)"
        return 1
    fi
    return 0
}

remote_size() {
    # Size of a remote file from a HEAD request (fallback when a directory listing lacks it).
    local tmp size
    tmp=$TMP_DIR/head.txt
    run_curl -sS -f -L -I -A "$USER_AGENT" --connect-timeout 20 --max-time 60 -o "$tmp" "$1"
    if [ "$CURL_CODE" -ne 0 ]; then
        REMOTE_ERROR="$1: curl exit $CURL_CODE ($CURL_ERROR)"
        return 1
    fi
    size=$(awk '{ sub(/\r$/, "") } tolower($1) == "content-length:" && $2 ~ /^[0-9]+$/ { s = $2 } END { print s }' "$tmp")
    rm -f "$tmp"
    if [ -z "$size" ]; then
        REMOTE_ERROR="$1: no Content-Length header"
        return 1
    fi
    printf '%s' "$size"
}

# ------------------------------------------------------------------ Remote catalog

# Catalog files (tab separated: name, url, size, md5, top directory, pieces).
cat_syzygy()  { printf '%s' "$TMP_DIR/syzygy.tsv"; }
cat_gaviota() { printf '%s' "$TMP_DIR/gaviota.tsv"; }
cat_gaviota_md5() { printf '%s' "$TMP_DIR/gaviota.md5"; }

build_syzygy_catalog() {
    # Joins download.txt (URLs), bytes.tsv (sizes) and md5 (checksums) by file name.
    local d
    d=$TMP_DIR
    remote_text "$BASE_URL/download.txt" "$d/download.txt" || return 1
    remote_text "$BASE_URL/bytes.tsv" "$d/bytes.tsv" || return 1
    remote_text "$BASE_URL/md5" "$d/md5" || return 1
    awk -v OFS="$TAB" '
        function pieces(n,    s) { s = n; sub(/\..*$/, "", s); gsub(/v/, "", s); return length(s) }
        { sub(/\r$/, "") }
        FILENAME == ARGV[1] { if (NF == 2 && $1 ~ /^[0-9]+$/) size[$2] = $1; next }
        FILENAME == ARGV[2] {
            if (NF != 2 || length($1) != 32 || $1 !~ /^[0-9A-Fa-f]+$/) next
            n = $2; sub(/^\*/, "", n)
            if (n ~ /^K[QRBNP]*vK[QRBNP]*\.rtb[wz]$/) md5[n] = tolower($1)
            next
        }
        NF == 0 { next }
        {   # ".../tables/standard/<top>/[<sub>/]<name>": the 7-piece files live in sub-directories.
            url = $1; n = split(url, p, "/"); top = ""
            for (i = 2; i < n; i++) if (p[i - 1] == "tables" && p[i] == "standard" && i + 1 < n) { top = p[i + 1]; break }
            if (top == "") next
            name = p[n]
            if (name !~ /^K[QRBNP]*vK[QRBNP]*\.rtb[wz]$/) next
            if (!(name in size) || !(name in md5)) { print "inconsistent Syzygy catalog: no size or checksum for " name > "/dev/stderr"; exit 2 }
            print name, url, size[name], md5[name], top, pieces(name); count++
        }
        END { if (count < 290) { print "the Syzygy catalog looks truncated (" count + 0 " files)" > "/dev/stderr"; exit 2 } }
    ' "$d/bytes.tsv" "$d/md5" "$d/download.txt" > "$(cat_syzygy)" 2> "$d/awk.err" || {
        REMOTE_ERROR=$(last_line "$d/awk.err")
        return 1
    }
    return 0
}

build_gaviota_catalog() {
    # Names and checksums from Gaviota.cp4.md5, sizes from the directory listing, with a HEAD
    # request as a fallback for a size missing from the listing.
    local d line name url size md5 top pieces
    d=$TMP_DIR
    remote_text "$BASE_URL/Gaviota/Gaviota.cp4.md5" "$(cat_gaviota_md5)" || return 1
    remote_text "$BASE_URL/Gaviota/" "$d/gaviota-listing.html" || return 1
    awk -v OFS="$TAB" -v base="$BASE_URL" '
        { sub(/\r$/, "") }
        FILENAME == ARGV[1] {
            if (match($0, /<a href="[a-z]+\.gtb\.cp4">/)) {
                n = substr($0, RSTART + 9, RLENGTH - 11)
                if ($NF ~ /^[0-9]+$/) size[n] = $NF
            }
            next
        }
        {
            if (NF != 2 || length($1) != 32 || $1 !~ /^[0-9A-Fa-f]+$/) next
            n = $2; sub(/^\*/, "", n)
            if (n !~ /^[a-z]+\.gtb\.cp4$/) next
            print n, base "/Gaviota/" n, (n in size ? size[n] : "-"), tolower($1), "Gaviota", 0; count++
        }
        END { if (count < 100) { print "the Gaviota catalog looks truncated (" count + 0 " files)" > "/dev/stderr"; exit 2 } }
    ' "$d/gaviota-listing.html" "$(cat_gaviota_md5)" > "$d/gaviota.raw" 2> "$d/awk.err" || {
        REMOTE_ERROR=$(last_line "$d/awk.err")
        return 1
    }
    : > "$(cat_gaviota)"
    while IFS="$TAB" read -r name url size md5 top pieces <&3; do
        if [ "$size" = - ]; then size=$(remote_size "$url") || return 1; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$url" "$size" "$md5" "$top" "$pieces" >> "$(cat_gaviota)"
    done 3< "$d/gaviota.raw"
    return 0
}

get_catalog() {
    # Everything the server knows (CATALOG=1), or offline mode (CATALOG=0: verification with
    # local checksums).
    CATALOG=0
    [ -n "$CURL_PATH" ] || return 0
    msg note 'Reading the file lists, sizes and checksums from Lichess...'
    if build_syzygy_catalog && build_gaviota_catalog; then
        CATALOG=1
        return 0
    fi
    msg warn "Lichess unreachable or unexpected answer: $REMOTE_ERROR"
    msg warn 'Offline mode: downloads are disabled, "Verify only" uses the local checksum files.'
    rm -f "$(cat_syzygy)" "$(cat_gaviota)" "$(cat_gaviota_md5)"
    return 0
}

set_entries() {
    # Remote entries making up a set, in server order (catalog lines).
    local dirs
    if [ "$(set_kind "$1")" = Gaviota ]; then cat "$(cat_gaviota)"; return 0; fi
    dirs=$(set_dirs "$1")
    awk -F "$TAB" -v dirs="$dirs" 'BEGIN { n = split(dirs, d, " "); for (i = 1; i <= n; i++) ok[d[i]] = 1 } ok[$5]' "$(cat_syzygy)"
}

# ------------------------------------------------------------------ Local files

# For each entry of a set (file 2) against a local table (file 1), the bytes still to download:
# a file is complete when its size is right; a shorter <name>.part, or a shorter <name>, is
# resumed. Output (tab separated): the entry, left, partial (left < size), final complete, a
# .part exists.
# shellcheck disable=SC2016
PLAN_AWK='
FILENAME == ARGV[1] { L[$2] = $1; next }
{
    name = $1; size = $3 + 0
    final = (name in L) ? L[name] + 0 : -1
    part = ((name ".part") in L) ? L[name ".part"] + 0 : -1
    if (final == size) left = 0
    else {
        have = (final > part) ? final : part
        if (have < 0 || have > size) left = size; else left = size - have
    }
    print $1, $2, $3, $4, $5, $6, left, (left < size ? 1 : 0), (final == size ? 1 : 0), (part >= 0 ? 1 : 0)
}'

plan_set() {
    # The plan above for a set ($1) and a local table file ($2).
    set_entries "$1" > "$TMP_DIR/plan-entries.tsv"
    awk -F "$TAB" -v OFS="$TAB" "$PLAN_AWK" "$2" "$TMP_DIR/plan-entries.tsv"
}

measure_set_status() {
    # Count, total size, remaining bytes and incomplete tables of a set ($1, local table $2)
    # into MS_COUNT, MS_TOTAL, MS_REMAINING, MS_PENDING, for the menu.
    local r
    r=$(plan_set "$1" "$2" | awk -F "$TAB" '{ c++; t += $3; r += $7; if ($9 != 1) p++ }
        END { printf "%d %.0f %.0f %d", c, t, r, p }')
    # shellcheck disable=SC2086
    set -- $r
    MS_COUNT=${1:-0}; MS_TOTAL=${2:-0}; MS_REMAINING=${3:-0}; MS_PENDING=${4:-0}
}

set_local_files() {
    # Local files belonging to a set ($1, local table $2): its tables, their .part files and
    # its checksum file, as "size<TAB>name" lines.
    awk -F "$TAB" -v kind="$(set_kind "$1")" -v maxp="$(set_maxpieces "$1")" -v md5name="$(set_md5name "$1")" '
        function pieces(n,    s) { s = n; sub(/\..*$/, "", s); gsub(/v/, "", s); return length(s) }
        {
            n = $2
            if (n == md5name) { print; next }
            if (kind == "Gaviota") { if (n ~ /^[a-z]+\.gtb\.cp4(\.part)?$/) print; next }
            if (n ~ /^K[QRBNP]*vK[QRBNP]*\.rtb[wz](\.part)?$/ && pieces(n) <= maxp) print
        }' "$2"
}

clear_set_files() {
    # "Purge": deletes the files of a set after a typed confirmation. Returns 1 if cancelled.
    local dir victims count bytes name size
    dir=$2/$(set_subdir "$1")
    victims=$TMP_DIR/victims.tsv
    local_table "$dir" > "$TMP_DIR/local.tsv"
    set_local_files "$1" "$TMP_DIR/local.tsv" > "$victims"
    count=$(count_lines "$victims")
    if [ "$count" -eq 0 ]; then
        msg info 'Nothing to purge.'
        return 0
    fi
    bytes=$(awk -F "$TAB" '{ b += $1 } END { printf "%.0f", b }' "$victims")
    msg warn "Purge deletes $count file(s) of $(set_label "$1"), $(fmt_size "$bytes"), in $dir"
    if ! read_confirmation 'This cannot be undone.' 'PURGE'; then
        msg info 'Purge cancelled, the job is kept.'
        return 1
    fi
    while IFS="$TAB" read -r size name <&3; do
        rm -f "$dir/$name"
    done 3< "$victims"
    msg ok "$count file(s) deleted."
    return 0
}

clear_partial_files() {
    # After "Abandon": reports the .part files left behind and offers to delete them.
    local parts sub dir count bytes size name
    parts=$TMP_DIR/parts.tsv
    : > "$parts"
    for sub in Syzygy Gaviota; do
        dir=$1/$sub
        [ -d "$dir" ] || continue
        local_table "$dir" | awk -F "$TAB" -v OFS="$TAB" -v d="$dir" '$2 ~ /\.part$/ { print $1, d "/" $2 }' >> "$parts"
    done
    count=$(count_lines "$parts")
    [ "$count" -gt 0 ] || return 0
    bytes=$(awk -F "$TAB" '{ b += $1 } END { printf "%.0f", b }' "$parts")
    msg info "$count partial download(s), $(fmt_size "$bytes"), remain. They are reused if the same tables are downloaded again."
    if read_yesno 'Delete them?' N; then
        while IFS="$TAB" read -r size name <&3; do rm -f "$name"; done 3< "$parts"
        msg ok 'Partial downloads deleted.'
    fi
}

# ------------------------------------------------------------------ Checksums

md5_extract() {
    # The hash out of the tool's output ($1) into $2, whatever the output format of the tool
    # (GNU and Darwin md5sum "hash  name", md5 -q "hash", openssl "MD5(name)= hash").
    awk -v f="$MD5_FLAVOR" 'NR == 1 { h = (f == "openssl") ? $NF : $1; h = tolower(h)
                                      if (length(h) == 32 && h ~ /^[0-9a-f]+$/) print h }' "$1" > "$2"
}

file_md5() {
    # MD5 of a file ($1) with the detected tool, in the foreground: the hash goes to $2,
    # errors to $3. Returns the tool's exit code.
    local rc raw
    raw=$2.raw
    case $MD5_FLAVOR in
        md5sum)  "$MD5_BIN" "$1" > "$raw" 2> "$3"; rc=$? ;;
        md5)     "$MD5_BIN" -q "$1" > "$raw" 2> "$3"; rc=$? ;;
        openssl) "$MD5_BIN" dgst -md5 "$1" > "$raw" 2> "$3"; rc=$? ;;
        *)       printf 'no MD5 tool\n' > "$3"; rc=1 ;;
    esac
    md5_extract "$raw" "$2"
    rm -f "$raw"
    return "$rc"
}

file_md5_bg() {
    # The same tool started in the background by bg_run ($1 rc file, $2 raw output, $3
    # errors) on file $4, so that Ctrl+C stops the tool itself and not a shell function.
    case $MD5_FLAVOR in
        md5sum)  bg_run "$1" "$2" "$3" "$MD5_BIN" "$4" ;;
        md5)     bg_run "$1" "$2" "$3" "$MD5_BIN" -q "$4" ;;
        openssl) bg_run "$1" "$2" "$3" "$MD5_BIN" dgst -md5 "$4" ;;
    esac
}

md5_list() {
    # "md5  name" or "md5 *name" lines of a checksum file ($1) -> "name<TAB>md5" (lower case),
    # in file order, for the kind of set $2; Syzygy lines above $3 pieces are ignored.
    awk -v OFS="$TAB" -v kind="$2" -v maxp="$3" '
        function pieces(n,    s) { s = n; sub(/\..*$/, "", s); gsub(/v/, "", s); return length(s) }
        {
            sub(/\r$/, "")
            if (NF != 2 || length($1) != 32 || $1 !~ /^[0-9A-Fa-f]+$/) next
            n = $2; sub(/^\*/, "", n)
            if (kind == "Gaviota") { if (n !~ /^[a-z]+\.gtb\.cp4$/) next }
            else { if (n !~ /^K[QRBNP]*vK[QRBNP]*\.rtb[wz]$/) next; if (maxp > 0 && pieces(n) > maxp) next }
            print n, tolower($1)
        }' "$1"
}

checksum_list() {
    # Expected checksums of a set ($1, directory $2) into SUMS_FILE ("name<TAB>md5") with
    # SUMS_SOURCE. A local checksum file covering the set comes first (works offline); when
    # Lichess is reachable it is cross-checked against the server and replaced by the server
    # list if they differ (a wrong local file must never get good tables deleted).
    local kind maxp candidates key candidate path remote
    kind=$(set_kind "$1"); maxp=$(set_maxpieces "$1")
    if [ "$kind" = Gaviota ]; then
        candidates=$(set_md5name "$1")
    else
        # Largest set first: 3-4-5-6-7.md5 covers every smaller set once filtered by pieces.
        candidates=''
        for key in $SYZYGY_KEYS; do
            [ "$(set_maxpieces "$key")" -ge "$maxp" ] && candidates="$(set_md5name "$key") $candidates"
        done
    fi
    remote=''
    if [ "$CATALOG" = 1 ]; then
        remote=$TMP_DIR/remote-sums.tsv
        set_entries "$1" | awk -F "$TAB" -v OFS="$TAB" '{ print $1, $4 }' > "$remote"
    fi
    for candidate in $candidates; do
        path=$2/$candidate
        [ -f "$path" ] || continue
        md5_list "$path" "$kind" "$maxp" > "$TMP_DIR/local-sums.tsv"
        [ "$(count_lines "$TMP_DIR/local-sums.tsv")" -gt 0 ] || continue
        if [ -n "$remote" ]; then
            awk -F "$TAB" '{ print $1 "=" $2 }' "$remote" | sort > "$TMP_DIR/cmp-remote"
            awk -F "$TAB" '{ print $1 "=" $2 }' "$TMP_DIR/local-sums.tsv" | sort > "$TMP_DIR/cmp-local"
            if ! cmp -s "$TMP_DIR/cmp-remote" "$TMP_DIR/cmp-local"; then
                msg warn "$candidate does not match the server checksums of $(set_label "$1"): using the server ones."
                break
            fi
        fi
        SUMS_FILE=$TMP_DIR/local-sums.tsv; SUMS_SOURCE=$path
        return 0
    done
    if [ -z "$remote" ]; then
        SUMS_ERROR="no local checksum file covers $(set_label "$1") and Lichess is unreachable"
        return 1
    fi
    SUMS_FILE=$remote; SUMS_SOURCE='the Lichess server'
    return 0
}

save_checksum_file() {
    # Writes the checksum file describing the directory; its path goes to CHECKSUM_FILE.
    # Syzygy: the largest set whose files are ALL complete (at least the chosen one) gets its
    # .md5, the other per-set .md5 files are removed: exactly one checksum file remains.
    local dir best key incomplete path other extra
    dir=$2/$(set_subdir "$1")
    if [ "$(set_kind "$1")" = Gaviota ]; then
        CHECKSUM_FILE=$dir/$(set_md5name "$1")
        cp "$(cat_gaviota_md5)" "$CHECKSUM_FILE"            # the server file, as is
        return 0
    fi
    local_table "$dir" > "$TMP_DIR/local.tsv"
    best=$1
    for key in $SYZYGY_KEYS; do
        [ "$(set_maxpieces "$key")" -gt "$(set_maxpieces "$best")" ] || continue
        incomplete=$(plan_set "$key" "$TMP_DIR/local.tsv" | awk -F "$TAB" '$9 != 1 { n++ } END { print n + 0 }')
        [ "$incomplete" -eq 0 ] && best=$key
    done
    # Same format and order as the server's md5 file (LF line ends, two spaces).
    path=$dir/$(set_md5name "$best")
    set_entries "$best" | awk -F "$TAB" '{ print $4 "  " $1 }' > "$path"
    for key in $SYZYGY_KEYS; do
        other=$dir/$(set_md5name "$key")
        [ "$other" != "$path" ] && [ -f "$other" ] && rm -f "$other"
    done
    extra=$(awk -F "$TAB" -v maxp="$(set_maxpieces "$best")" '
        function pieces(n,    s) { s = n; sub(/\..*$/, "", s); gsub(/v/, "", s); return length(s) }
        $2 ~ /^K[QRBNP]*vK[QRBNP]*\.rtb[wz]$/ && pieces($2) > maxp { n++ } END { print n + 0 }' "$TMP_DIR/local.tsv")
    if [ "$extra" -gt 0 ]; then
        msg note "$extra table file(s) of a larger, incomplete set are not covered by $(set_md5name "$best")."
    fi
    CHECKSUM_FILE=$path
    return 0
}

verify_status() {
    # Progress line of a verification: $1 index, $2 count, $3 name, $4 done, $5 total, $6 started.
    local line
    line=$(awk -v idx="$1" -v cnt="$2" -v name="$3" -v done="$4" -v total="$5" -v started="$6" -v now="$(date +%s)" "$AWK_LIB"'
        BEGIN {
            elapsed = now - started
            speed = (elapsed > 0) ? done / elapsed : 0
            eta = (speed > 0) ? fmt_duration((total - done) / speed) : "?"
            pct = (total > 0) ? 100 * done / total : 100
            printf "Verifying [%s/%s] %s | %s / %s (%.1f%%) | %s/s | ETA %s", idx, cnt, name, fmt_size(done), fmt_size(total), pct, fmt_size(speed), eta
        }')
    status "$line"
}

run_verification() {
    # Hashes the files of a set in $1 against SUMS_FILE. Progress is saved in the job state
    # every few seconds (and on Ctrl+C): an interrupted verification resumes where it
    # stopped; files validated before are only re-checked for presence and size.
    # Results: PROBLEMS_FILE ("KIND<TAB>name<TAB>detail" lines) and CHECKED.
    local plan skipped todo total count started last_save index done_bytes name size md5 hash rc detail now tick
    plan=$TMP_DIR/vplan.tsv
    PROBLEMS_FILE=$TMP_DIR/problems.tsv
    local_table "$1" > "$TMP_DIR/local.tsv"
    [ -n "$JOB_OK_FILE" ] || { JOB_OK_FILE=$TMP_DIR/ok.list; : > "$JOB_OK_FILE"; }
    # Files validated before an interruption, still present with the same size, are skipped.
    awk -F "$TAB" -v OFS="$TAB" '
        FILENAME == ARGV[1] { L[$2] = $1; next }
        FILENAME == ARGV[2] { split($0, a, " "); OK[a[2]] = a[1]; next }
        {
            name = $1
            if ((name in OK) && (name in L) && L[name] + 0 == OK[name] + 0) { print "SKIP", name, L[name]; next }
            if (!(name in L)) { print "MISSING", name, ""; next }
            print "TODO", name, L[name], $2
        }' "$TMP_DIR/local.tsv" "$JOB_OK_FILE" "$SUMS_FILE" > "$plan"
    awk -F "$TAB" '$1 == "SKIP" { print $3 " " $2 }' "$plan" > "$TMP_DIR/ok.next"
    mv -f "$TMP_DIR/ok.next" "$JOB_OK_FILE"
    awk -F "$TAB" -v OFS="$TAB" '$1 == "MISSING" { print $1, $2, "" }' "$plan" > "$PROBLEMS_FILE"
    skipped=$(awk -F "$TAB" '$1 == "SKIP" { n++ } END { print n + 0 }' "$plan")
    if [ "$skipped" -gt 0 ]; then
        msg note "$skipped file(s) already verified before the interruption (still present, same size)."
    fi
    todo=$TMP_DIR/vtodo.tsv
    awk -F "$TAB" -v OFS="$TAB" '$1 == "TODO" { print $2, $3, $4 }' "$plan" > "$todo"
    count=$(count_lines "$todo")
    total=$(awk -F "$TAB" '{ t += $2 } END { printf "%.0f", t }' "$todo")
    CHECKED=$(count_lines "$SUMS_FILE")
    JOB_SOURCE=$SUMS_SOURCE
    started=$(date +%s); last_save=$started; done_bytes=0; index=0
    VERIFY_ACTIVE=1
    while IFS="$TAB" read -r name size md5 <&3; do
        index=$((index + 1))
        verify_status "$index" "$count" "$name" "$done_bytes" "$total" "$started"
        if [ "$size" -ge "$BG_MD5_BYTES" ]; then
            # Big file: hashed in the background so that the progress line keeps living.
            file_md5_bg "$TMP_DIR/md5.rc" "$TMP_DIR/md5.raw" "$TMP_DIR/md5.err" "$1/$name"
            tick=0
            until [ -s "$TMP_DIR/md5.rc" ]; do
                sleep "$POLL"
                tick=$((tick + 1))
                if [ "$tick" -ge "$POLL_PER_SEC" ]; then
                    tick=0
                    verify_status "$index" "$count" "$name" "$done_bytes" "$total" "$started"
                fi
            done
            bg_wait
            rc=$(cat "$TMP_DIR/md5.rc")
            md5_extract "$TMP_DIR/md5.raw" "$TMP_DIR/md5.hash"
        else
            file_md5 "$1/$name" "$TMP_DIR/md5.hash" "$TMP_DIR/md5.err"
            rc=$?
        fi
        hash=$(cat "$TMP_DIR/md5.hash" 2>/dev/null)
        if [ "$rc" -ne 0 ] || [ -z "$hash" ]; then
            detail=$(last_line "$TMP_DIR/md5.err")
            printf 'UNREADABLE\t%s\t%s\n' "$name" "${detail:-read error}" >> "$PROBLEMS_FILE"
        elif [ "$hash" = "$md5" ]; then
            printf '%s %s\n' "$size" "$name" >> "$JOB_OK_FILE"
        else
            printf 'CORRUPT\t%s\t\n' "$name" >> "$PROBLEMS_FILE"
        fi
        done_bytes=$((done_bytes + size))
        now=$(date +%s)
        if [ $((now - last_save)) -ge "$CHECKPOINT_SEC" ]; then
            save_job_state
            last_save=$now
        fi
    done 3< "$todo"
    save_job_state                                     # also done by the Ctrl+C handler
    VERIFY_ACTIVE=0
    clear_status
}

# ------------------------------------------------------------------ Jobs

download_status() {
    # Progress line of a download: $1 name, $2 size. File, whole job, speed over the last
    # 30 s (samples "time:bytes" in P_SAMPLES), ETA.
    local name size now done_bytes first line speed span
    name=$1; size=$2
    now=$(date +%s)
    done_bytes=$((P_DONE_BEFORE + P_FILE_DONE - P_FILE_START))
    # shellcheck disable=SC2086
    set -- $P_SAMPLES "$now:$done_bytes"
    while [ $# -gt 2 ] && [ $((now - ${1%%:*})) -gt 30 ]; do shift; done
    P_SAMPLES=$*
    first=$1
    span=$((now - ${first%%:*}))
    speed=0
    [ "$span" -gt 0 ] && speed=$(( (done_bytes - ${first#*:}) / span ))
    line=$(awk -v idx="$P_INDEX" -v cnt="$P_COUNT" -v name="$name" -v fdone="$P_FILE_DONE" -v fsize="$size" \
               -v done="$done_bytes" -v total="$P_TOTAL" -v speed="$speed" "$AWK_LIB"'
        BEGIN {
            fp = (fsize > 0) ? 100 * fdone / fsize : 100
            jp = (total > 0) ? 100 * done / total : 100
            eta = (speed > 0) ? fmt_duration((total - done) / speed) : "?"
            printf "[%s/%s] %s %.0f%% | %s / %s (%.1f%%) | %s/s | ETA %s", idx, cnt, name, fp, fmt_size(done), fmt_size(total), jp, fmt_size(speed), eta
        }')
    status "$line"
}

download_file() {
    # Downloads one file ($1 name, $2 url, $3 size, $4 md5) into $5/<name>.part, restarting
    # curl (which resumes with -C -) until the file is complete or makes no more progress;
    # flushes it to disk, renames it, and MD5-checks it when $6 is 1 (files resumed after
    # an interrupted run, repairs). Returns 0, or 1 with PROBLEM set.
    local name url size md5 dir check final part pass length partlength current stalled lastlength
    local code message tick delay hash
    name=$1; url=$2; size=$3; md5=$4; dir=$5; check=$6
    final=$dir/$name
    part=$final.part
    pass=1
    while [ "$pass" -le 2 ]; do
        # 1. Normalise what is on disk.
        if [ -e "$final" ]; then
            length=$(file_size "$final")
            if [ "$length" -eq "$size" ]; then
                rm -f "$part"
                return 0                                  # completed meanwhile
            fi
            partlength=-1
            [ -e "$part" ] && partlength=$(file_size "$part")
            if [ "$length" -lt "$size" ] && [ "$length" -gt "$partlength" ]; then
                rm -f "$part"                             # partial file under its final name: resume it
                mv -f "$final" "$part"
            else
                rm -f "$final"                            # oversized (corrupt) or behind the .part file
            fi
        fi
        current=$(file_size "$part")
        if [ "$current" -gt "$size" ]; then
            msg warn "$name: partial file larger than the remote one, starting over"
            rm -f "$part"
            current=0
        fi
        P_FILE_START=$current
        P_FILE_DONE=$current
        # 2. Download. curl's own --retry is NOT used: on a retry it truncates the file back to
        #    where that curl started, throwing away everything received meanwhile. A new curl
        #    with -C - resumes from the last byte written instead.
        stalled=0
        lastlength=$current
        while [ "$current" -lt "$size" ]; do
            bg_run "$TMP_DIR/curl.rc" /dev/null /dev/null \
                "$CURL_PATH" --stderr "$TMP_DIR/curl.err" -sS -f -L -A "$USER_AGENT" \
                --connect-timeout 30 --speed-limit 1024 --speed-time 120 -C - -o "$part" "$url"
            tick=0
            until [ -s "$TMP_DIR/curl.rc" ]; do
                sleep "$POLL"
                tick=$((tick + 1))
                if [ "$tick" -ge "$POLL_PER_SEC" ]; then
                    tick=0
                    P_FILE_DONE=$(file_size "$part")
                    download_status "$name" "$size"
                fi
            done
            bg_wait
            code=$(cat "$TMP_DIR/curl.rc")
            message=$(last_line "$TMP_DIR/curl.err")
            rm -f "$TMP_DIR/curl.err"
            current=$(file_size "$part")
            P_FILE_DONE=$current
            download_status "$name" "$size"
            if [ "$code" -eq 0 ] && [ "$current" -eq "$size" ]; then break; fi
            [ "$code" -eq 0 ] && message="size mismatch: $current bytes instead of $size"
            if [ "$current" -gt "$size" ] || [ "$code" -eq 33 ]; then
                # Oversized result, or the server refused the byte range: this file starts over.
                rm -f "$part"
                current=0
                P_FILE_START=0
                P_FILE_DONE=0
                P_SAMPLES=''                              # the speed window would otherwise go negative
            fi
            if [ "$code" -eq 22 ] && printf '%s' "$message" | grep -Eq '(^|[^0-9])404([^0-9]|$)'; then
                PROBLEM="$name: not found on the server (404)"
                return 1
            fi
            if [ "$current" -gt "$lastlength" ]; then stalled=0; else stalled=$((stalled + 1)); fi
            lastlength=$current
            if [ "$stalled" -ge "$MAX_STALLED" ]; then
                PROBLEM="$name: curl exit $code, $message"
                return 1
            fi
            delay=$((5 << stalled))
            [ "$delay" -gt 60 ] && delay=60
            msg warn "$name: curl exit $code ($message), new attempt in ${delay}s"
            sleep "$delay"
        done
        # 3. Data on disk first, then the atomic rename that makes the table visible to engines.
        sync_file "$part"
        mv -f "$part" "$final"
        P_DONE_BEFORE=$((P_DONE_BEFORE + size - P_FILE_START))
        P_FILE_START=0
        P_FILE_DONE=0
        [ "$check" = 1 ] || return 0
        # 4. MD5 check (resumed after an interruption, or repair).
        status "Checking the MD5 of $name..."
        file_md5 "$final" "$TMP_DIR/md5.hash" "$TMP_DIR/md5.err"
        hash=$(cat "$TMP_DIR/md5.hash" 2>/dev/null)
        [ "$hash" = "$md5" ] && return 0
        msg warn "$name: MD5 mismatch, downloading it again from scratch"
        P_TOTAL=$((P_TOTAL + size))                       # the job grows by one full download
        rm -f "$final"
        pass=$((pass + 1))
    done
    PROBLEM="$name: MD5 mismatch even after a full download"
    return 1
}

download_job() {
    # Downloads what is missing in a set ($1, root $2). Modes ($3):
    #   New      asks for confirmation, then creates the job state;
    #   Restart  after a purge: creates the job state without asking again;
    #   Resume   the job state exists;
    #   Repair   after a failed verification: every downloaded file is MD5-checked and no
    #            verification is offered at the end.
    # In every mode, a file that was partial when the job started (.part or short final file)
    # is MD5-checked once complete: after a power cut its tail may hold unwritten blocks.
    local dir mode work total count largest big margin name url size md5 top pieces left partial finalok haspart
    local failed check bytes code
    dir=$2/$(set_subdir "$1"); mode=$3
    mkdir -p "$dir" || { msg error "Cannot create $dir"; return 1; }
    set_entries "$1" > "$TMP_DIR/entries.tsv"
    local_table "$dir" > "$TMP_DIR/local.tsv"
    work=$TMP_DIR/work.tsv
    plan_set "$1" "$TMP_DIR/local.tsv" > "$TMP_DIR/plan.tsv"
    : > "$work"
    while IFS="$TAB" read -r name url size md5 top pieces left partial finalok haspart <&3; do
        if [ "$left" -eq 0 ] && [ "$finalok" = 1 ]; then
            [ "$haspart" = 1 ] && rm -f "$dir/$name.part"   # stray .part next to a complete table
            continue
        fi
        # Bytes left, or a complete .part that still has to be flushed, renamed and MD5-checked
        # (the run stopped between the end of curl and the rename): download_file does it.
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$url" "$size" "$md5" "$left" "$partial" >> "$work"
    done 3< "$TMP_DIR/plan.tsv"
    count=$(count_lines "$work")
    if [ "$count" -eq 0 ]; then
        msg ok "$(set_label "$1"): the $(count_lines "$TMP_DIR/entries.tsv") files are already present."
    else
        total=$(awk -F "$TAB" '{ t += $5 } END { printf "%.0f", t }' "$work")
        largest=$(awk -F "$TAB" '$3 > m { m = $3 } END { printf "%.0f", m }' "$work")
        # --- Safety checks, before anything is written ---
        volume_info "$dir"
        if is_fat "$VOL_FS" && [ "$largest" -ge 4294967296 ]; then
            msg error "$dir is formatted $VOL_FS, which cannot store files of 4 GiB or more (largest here: $(fmt_size "$largest")). Use another file system."
            return 1
        fi
        margin=$(awk -v t="$total" 'BEGIN { printf "%.0f", 1073741824 + 0.005 * t }')
        if [ "$VOL_FREE" -ge 0 ] && [ "$VOL_FREE" -lt $((total + margin)) ]; then
            msg error "Not enough free space for $(set_label "$1") in $dir:"
            msg info "  to download $(fmt_size "$total") + safety margin $(fmt_size "$margin"), free $(fmt_size "$VOL_FREE")"
            return 1
        fi
        # --- Confirmation and job state (new jobs) ---
        msg info "$(set_label "$1"): $count file(s) to download, $(fmt_size "$total"), into $dir"
        if [ "$mode" = New ]; then
            if [ "$1" = 34567 ]; then
                big=$(awk -F "$TAB" '$3 >= 4294967296 { n++ } END { print n + 0 }' "$work")
                msg warn 'This set is huge. Please read before starting:'
                msg info "  largest file    : $(fmt_size "$largest")"
                msg info "  at 1 Gbit/s     : about $(fmt_duration "$(awk -v t="$total" 'BEGIN { print t / 125000000 }')") (theoretical line rate)"
                msg info "  at 100 Mbit/s   : about $(fmt_duration "$(awk -v t="$total" 'BEGIN { print t / 12500000 }')")"
                msg info "  $big files are 4 GiB or larger: FAT32 cannot store them."
                msg info '  Ctrl+C is safe at any time: the next run resumes where it stopped.'
                if ! read_confirmation 'Start this download?' 'YES'; then
                    msg info 'Cancelled.'
                    return 0
                fi
            elif ! read_yesno 'Start the download?' Y; then
                msg info 'Cancelled.'
                return 0
            fi
        fi
        if [ "$mode" = New ] || [ "$mode" = Restart ]; then
            init_job_state Download "$1" "$2"
            save_job_state
        fi
        # --- Download loop ---
        msg note 'Downloading. Ctrl+C stops at any time; run the script again to resume.'
        P_INDEX=0; P_COUNT=$count; P_TOTAL=$total; P_DONE_BEFORE=0; P_FILE_START=0; P_FILE_DONE=0; P_SAMPLES=''
        failed=0
        while IFS="$TAB" read -r name url size md5 left partial <&3; do
            P_INDEX=$((P_INDEX + 1))
            check=0
            if [ "$mode" = Repair ] || [ "$partial" = 1 ]; then check=1; fi
            PROBLEM=''
            if download_file "$name" "$url" "$size" "$md5" "$dir" "$check"; then
                [ "$PLAIN" = 1 ] && msg info "[$P_INDEX/$P_COUNT] $name OK"
            else
                failed=$((failed + 1))
                msg error "$PROBLEM"
            fi
        done 3< "$work"
        clear_status
        if [ "$failed" -gt 0 ]; then
            msg error "$failed file(s) could not be downloaded. The job is kept: run the script again and choose Resume."
            return 1
        fi
    fi
    # --- Success: checksum file, end of the job, optional verification ---
    save_checksum_file "$1" "$2"
    clear_job_state
    msg ok "$(set_label "$1") is complete in $dir (checksum file: $(basename "$CHECKSUM_FILE"))."
    [ "$mode" = Repair ] && return 0
    bytes=$(awk -F "$TAB" '{ b += $3 } END { printf "%.0f", b }' "$TMP_DIR/entries.tsv")
    if read_yesno "Verify the MD5 checksums of the $(count_lines "$TMP_DIR/entries.tsv") files now ($(fmt_size "$bytes") to read)?" N; then
        verify_job "$1" "$2" 0
        return $?
    fi
    return 0
}

resolve_verification_result() {
    # Reports a verification of set $1 (root $2). CORRUPT files are deleted (their size is
    # right, so a download would skip them), then the repair becomes a download job, kept
    # until it succeeds.
    local dir count shown kind name detail line corrupt unreadable tofetch
    count=$(count_lines "$PROBLEMS_FILE")
    if [ "$count" -eq 0 ]; then
        clear_job_state
        msg ok "$(set_label "$1"): the $CHECKED files are verified, checksums OK."
        return 0
    fi
    dir=$2/$(set_subdir "$1")
    shown=0
    while IFS="$TAB" read -r kind name detail <&3; do
        shown=$((shown + 1))
        [ "$shown" -le 30 ] || break
        line=$(printf '%-10s %s' "$kind" "$name")
        [ -n "$detail" ] && line="$line ($detail)"
        msg error "$line"
    done 3< "$PROBLEMS_FILE"
    [ "$count" -gt 30 ] && msg info "... and $((count - 30)) more."
    corrupt=0
    while IFS="$TAB" read -r kind name detail <&3; do
        [ "$kind" = CORRUPT ] || continue
        rm -f "$dir/$name"
        corrupt=$((corrupt + 1))
    done 3< "$PROBLEMS_FILE"
    [ "$corrupt" -gt 0 ] && msg warn "$corrupt corrupt file(s) deleted."
    unreadable=$(awk -F "$TAB" '$1 == "UNREADABLE" { n++ } END { print n + 0 }' "$PROBLEMS_FILE")
    if [ "$unreadable" -gt 0 ]; then
        msg warn "$unreadable file(s) could not be read (disk or permission problem); they were left untouched."
    fi
    tofetch=$((count - unreadable))
    if [ "$tofetch" -eq 0 ]; then
        clear_job_state
        return 1
    fi
    init_job_state Download "$1" "$2"
    save_job_state
    if [ "$CATALOG" != 1 ]; then
        msg info 'Run the script again when Lichess is reachable and choose Resume to download them.'
        return 1
    fi
    if read_yesno "Download the $tofetch missing or deleted file(s) now?" Y; then
        download_job "$1" "$2" Repair
        return $?
    fi
    msg info 'The job is kept: run the script again and choose Resume to download them.'
    return 1
}

verify_job() {
    # "Verify only", or the verification offered after a download, for set $1 (root $2).
    # $3 = 1 when resuming the saved job (JOB_* already loaded, checkpoint included).
    local dir
    dir=$2/$(set_subdir "$1")
    if [ ! -d "$dir" ]; then
        msg error "Nothing to verify: $dir does not exist."
        [ "$3" = 1 ] && clear_job_state
        return 1
    fi
    if ! checksum_list "$1" "$dir"; then
        msg error "$SUMS_ERROR"
        return 1
    fi
    if [ "$3" != 1 ]; then
        init_job_state Verify "$1" "$2"
        JOB_OK_FILE=$TMP_DIR/ok.list
        : > "$JOB_OK_FILE"
        save_job_state
    fi
    msg info "Verifying $(set_label "$1"): $(count_lines "$SUMS_FILE") files, checksums from $SUMS_SOURCE"
    msg note 'Ctrl+C stops at any time; the next run resumes the verification.'
    run_verification "$dir"
    resolve_verification_result "$1" "$2"
}

show_menu() {
    # Two steps: the set, then the action. RUN_SET and RUN_ACTION on success; returns 1 to quit.
    local i key line todo
    while :; do
        msg info ''
        msg title "Destination: $1"
        line=$(free_space_text "$1")
        [ -n "$line" ] && msg note "Free space : $line"
        local_table "$1/Syzygy" > "$TMP_DIR/menu-syzygy.tsv"
        local_table "$1/Gaviota" > "$TMP_DIR/menu-gaviota.tsv"
        i=0
        for key in $MENU_KEYS; do
            i=$((i + 1))
            line=$(printf '  %s) %-17s' "$i" "$(set_label "$key")")
            if [ "$CATALOG" = 1 ]; then
                if [ "$(set_kind "$key")" = Gaviota ]; then measure_set_status "$key" "$TMP_DIR/menu-gaviota.tsv"
                else measure_set_status "$key" "$TMP_DIR/menu-syzygy.tsv"; fi
                if [ "$MS_PENDING" -eq 0 ]; then todo='complete'
                elif [ "$MS_REMAINING" -eq 0 ]; then todo="to finalize: $MS_PENDING complete .part file(s)"
                else todo="to download: $(fmt_size "$MS_REMAINING")"; fi
                line="$line$(printf ' %11s  %4s files  %s' "$(fmt_size "$MS_TOTAL")" "$MS_COUNT" "$todo")"
            fi
            msg info "$line"
        done
        msg info '  Q) Quit'
        read_choice 'Tables' '1 2 3 4 Q' '' || return 1
        [ "$ANSWER" = Q ] && return 1
        i=0
        for key in $MENU_KEYS; do
            i=$((i + 1))
            [ "$i" -eq "$ANSWER" ] && break
        done
        if [ "$CATALOG" != 1 ]; then
            read_choice "$(set_label "$key") (offline): [V] Verify only, [B] Back" 'V B' '' || return 1
        else
            read_choice "$(set_label "$key"): [D] Download, [V] Verify only, [B] Back" 'D V B' '' || return 1
        fi
        case $ANSWER in
            B) continue ;;
            D) RUN_SET=$key; RUN_ACTION=Download; return 0 ;;
            *) RUN_SET=$key; RUN_ACTION=Verify; return 0 ;;
        esac
    done
}

usage() {
    printf 'Usage: %s [--root DIR] [--curl PATH]\n' "$(basename "$SCRIPT_PATH")"
    printf '  --root DIR    Destination: Gaviota/ and Syzygy/ are created below it (default: the directory of the script).\n'
    printf '  --curl PATH   curl executable (default: the curl found in PATH).\n'
}

main() {
    # Lock, pending job (resume / purge / abandon / quit), menu, job. Returns the exit code.
    local code root
    while [ $# -gt 0 ]; do
        case $1 in
            --root)   [ $# -ge 2 ] || { usage >&2; return 1; }; ROOT_ARG=$2; ROOT_GIVEN=1; shift 2 ;;
            --root=*) ROOT_ARG=${1#--root=}; ROOT_GIVEN=1; shift ;;
            --curl)   [ $# -ge 2 ] || { usage >&2; return 1; }; CURL_ARG=$2; shift 2 ;;
            --curl=*) CURL_ARG=${1#--curl=}; shift ;;
            -h|--help) usage; return 0 ;;
            *) usage >&2; return 1 ;;
        esac
    done
    [ -n "$ROOT_ARG" ] || ROOT_ARG=$SCRIPT_DIR

    msg title "get-tablebases $SCRIPT_VERSION - Lichess mirror $BASE_URL"
    if [ -z "$MD5_FLAVOR" ]; then
        msg error 'No MD5 tool found (md5sum, md5 or openssl).'
        return 1
    fi
    lock_instance
    code=$?
    [ "$code" -eq 0 ] || return "$code"

    CURL_PATH=$(resolve_curl "$CURL_ARG")
    if [ -z "$CURL_PATH" ]; then
        msg warn 'curl not found: downloads are disabled (--curl can point to a curl executable).'
    else
        msg note "curl $(curl_version): $CURL_PATH"
    fi

    root=$(resolve_root "$ROOT_ARG")
    RUN_SET=''; RUN_ACTION=''; RUN_MODE=''; RUN_STATE=0
    if read_job_state; then
        if [ "$ROOT_GIVEN" = 1 ] && [ "$root" != "$JOB_ROOT" ]; then
            msg note "--root is ignored while a job is pending: its destination is $JOB_ROOT"
        fi
        root=$JOB_ROOT
        msg warn 'An unfinished job was found:'
        msg info "  $JOB_ACTION $(set_label "$JOB_SET") into $root (started $(fmt_stamp "$JOB_STARTED"))"
        if [ "$JOB_ACTION" = Download ]; then
            read_choice '[R] Resume, [P] Purge the files of this set and start over, [A] Abandon (keep the files), [Q] Quit' 'R P A Q' '' || return 0
        else
            read_choice '[R] Resume, [P] Restart the verification from the first file, [A] Abandon, [Q] Quit' 'R P A Q' '' || return 0
        fi
        case $ANSWER in
            Q) return 0 ;;
            R) RUN_SET=$JOB_SET; RUN_ACTION=$JOB_ACTION; RUN_MODE=Resume; RUN_STATE=1 ;;
            P) write_lock_info "Purge $(set_label "$JOB_SET") into $root"
               if [ "$JOB_ACTION" = Download ]; then
                   clear_set_files "$JOB_SET" "$root" || return 0
                   RUN_SET=$JOB_SET; RUN_ACTION=Download; RUN_MODE=Restart; RUN_STATE=0
               else
                   RUN_SET=$JOB_SET; RUN_ACTION=Verify; RUN_MODE=New; RUN_STATE=0
               fi ;;
            *) clear_job_state
               msg ok 'Job abandoned, files kept.'
               clear_partial_files "$root"
               root=$(resolve_root "$ROOT_ARG") ;;
        esac
    fi

    get_catalog
    if [ -z "$RUN_SET" ]; then
        show_menu "$root" || return 0
        RUN_MODE=New; RUN_STATE=0
    fi
    write_lock_info "$RUN_ACTION $(set_label "$RUN_SET") into $root"
    if [ "$RUN_ACTION" = Verify ]; then
        verify_job "$RUN_SET" "$root" "$RUN_STATE"
        return $?
    fi
    if [ "$CATALOG" != 1 ]; then
        msg error 'Downloading needs Lichess and curl. Run the script again when they are available.'
        return 1
    fi
    download_job "$RUN_SET" "$root" "$RUN_MODE"
}

# ------------------------------------------------------------------ Entry point

cleanup() {
    # Normal end, error or signal: no curl or md5 left behind, scratch files gone, lock
    # released. The job state stays, so the next run offers to resume.
    bg_kill
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    unlock_instance
}

on_signal() {
    # Ctrl+C (or kill): a running verification saves its checkpoint first.
    clear_status
    [ "$VERIFY_ACTIVE" = 1 ] && save_job_state
    cleanup
    trap - EXIT
    exit 1
}

# Lock and state files live next to the script (not in the destination): a run started
# without --root still finds the pending job, whose destination is recorded inside.
case $0 in */*) SCRIPT_PATH=$0;; *) SCRIPT_PATH=$(command -v "$0" 2>/dev/null || printf '%s' "$0");; esac
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd -P) || SCRIPT_DIR=$PWD
SCRIPT_BASE=$(basename "$SCRIPT_PATH" .sh)
LOCK_PATH=$SCRIPT_DIR/$SCRIPT_BASE.lock
STATE_PATH=$SCRIPT_DIR/$SCRIPT_BASE.state

[ -t 1 ] || PLAIN=1
detect_tools
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/get-tablebases.XXXXXX") || { printf 'ERROR: cannot create a temporary directory\n'; exit 1; }
trap cleanup EXIT
trap on_signal INT TERM HUP

# GET_TABLEBASES_NO_MAIN=1 . ./get-tablebases.sh loads the functions without running (tests).
if [ -z "${GET_TABLEBASES_NO_MAIN:-}" ]; then
    main "$@"
    exit $?
fi
