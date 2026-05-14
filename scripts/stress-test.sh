#!/usr/bin/env bash
# Stress-test Watt by simulating a real-world workload that mirrors what
# corporate security agents (Falcon, Tenable, Zscaler) trigger when scanning
# a developer's machine.
#
# This intentionally produces a *spiky* workload — short bursts of heavy CPU
# and IO interleaved with idle periods — to exercise Watt's window-integrated
# episode detector. A naïve detector that watches instantaneous samples would
# never trigger on this; Watt should catch it.
#
# What runs:
#   1. File churn (writer): creates and rewrites ~10k files in a temp dir
#      every few seconds. Triggers any real-time AV scanner on the machine.
#   2. File scan (reader): walks every file the writer produced and computes
#      checksums. If you have no AV installed, this stands in for one.
#   3. CPU baker: bursty `yes` workload, 8s on / 2s off, on 6 cores. Mimics
#      a security agent that wakes, scans, sleeps.
#   4. Optional: airchat review codex on a real repo (if --repo given and
#      the airchat CLI is installed).
#
# Usage:
#   scripts/stress-test.sh                       # default 12 minutes
#   scripts/stress-test.sh --duration 5m
#   scripts/stress-test.sh --repo /path/to/big-repo
#   scripts/stress-test.sh --files 20000
#   scripts/stress-test.sh --no-airchat          # skip airchat even if available

set -euo pipefail

DURATION="12m"
REPO=""
FILE_COUNT=10000
USE_AIRCHAT=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)   DURATION="$2"; shift 2 ;;
        --repo)       REPO="$2"; shift 2 ;;
        --files)      FILE_COUNT="$2"; shift 2 ;;
        --no-airchat) USE_AIRCHAT=0; shift ;;
        -h|--help)    sed -n '/^# Stress-test/,/^$/p' "$0" | sed 's/^#\s\?//'; exit 0 ;;
        *)            echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

duration_to_seconds() {
    local d="$1"
    case "$d" in
        *h) echo $(( ${d%h} * 3600 )) ;;
        *m) echo $(( ${d%m} * 60 )) ;;
        *s) echo "${d%s}" ;;
        *)  echo "$d" ;;
    esac
}
END_SEC=$(( $(date +%s) + $(duration_to_seconds "$DURATION") ))

WATT_PID=$(pgrep -x Watt | head -1 || true)
if [[ -z "$WATT_PID" ]]; then
    echo "warning: Watt does not appear to be running — start it before this test"
fi

WORK_DIR="$(mktemp -d -t watt-stress)"

# Put ourselves in a new process group so we can kill the entire group on exit,
# catching `yes` children spawned by cpu_baker across subshell boundaries.
set -m
SCRIPT_PGID=$(ps -o pgid= -p $$ | tr -d ' ')

cleanup() {
    # Kill every process in our process group except the shell itself
    kill -9 -- "-${SCRIPT_PGID}" 2>/dev/null || true
    # Belt-and-suspenders: kill any stray `yes` owned by this user
    pkill -9 -x yes 2>/dev/null || true
    rm -rf "$WORK_DIR"
    echo
    echo "cleanup done"
}
trap cleanup EXIT INT TERM

echo "=== Watt stress test ==="
echo "Watt pid:    ${WATT_PID:-not running}"
echo "Duration:    $DURATION"
echo "Work dir:    $WORK_DIR"
echo "Repo:        ${REPO:-(synthetic only)}"
echo "File count:  $FILE_COUNT"
echo "Use airchat: $USE_AIRCHAT"
echo

writer() {
    local i=0
    while [[ $(date +%s) -lt $END_SEC ]]; do
        local target="$WORK_DIR/file_$((i % FILE_COUNT)).txt"
        head -c 32768 /dev/urandom | base64 > "$target"
        if (( i % 7 == 0 )); then
            { date; head -c 16384 /dev/urandom | base64; } >> "$target"
        fi
        i=$((i + 1))
        if (( i % 200 == 0 )); then sleep 0.01; fi
    done
}

reader() {
    while [[ $(date +%s) -lt $END_SEC ]]; do
        find "$WORK_DIR" -type f -print0 2>/dev/null \
            | xargs -0 -P 4 -n 50 cksum >/dev/null 2>&1 || true
    done
}

cpu_baker() {
    local cores="$1"
    local pids=()
    while [[ $(date +%s) -lt $END_SEC ]]; do
        pids=()
        for _ in $(seq 1 "$cores"); do
            yes >/dev/null &
            pids+=($!)
        done
        sleep 8
        kill "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
        sleep 2
    done
}

airchat_loop() {
    local repo="$1"
    while [[ $(date +%s) -lt $END_SEC ]]; do
        ( cd "$repo" && airchat review codex || true ) >/dev/null 2>&1
        sleep 30
    done
}

echo "Starting writer (file churn)…"
writer &

echo "Starting reader (file scan)…"
reader &

echo "Starting CPU baker (bursty 8s on / 2s off)…"
cpu_baker 6 &

if (( USE_AIRCHAT )) && [[ -n "$REPO" ]] && command -v airchat >/dev/null 2>&1; then
    echo "Starting airchat review loop on $REPO…"
    airchat_loop "$REPO" &
fi

echo
echo "Running. Open the Watt menubar (or report window) — values should climb."
echo "Will run until $(date -r $END_SEC '+%H:%M:%S'). Ctrl-C to stop early."
echo

while [[ $(date +%s) -lt $END_SEC ]]; do
    REMAINING=$(( END_SEC - $(date +%s) ))
    FILES_NOW=$(find "$WORK_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    printf "\r  %ss remaining | files in flight: %s" "$REMAINING" "$FILES_NOW"
    sleep 5
done
echo
echo
echo "=== Stress test complete."
echo "Open Watt → Reports — you should see at least one episode if the"
echo "windowed mean exceeded threshold for ≥ 10 minutes of contiguous data."
