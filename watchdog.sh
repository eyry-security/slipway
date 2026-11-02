#!/usr/bin/env bash
# Slipway queue watchdog.
#
# Reads <name>-progress.log files written by run.sh and classifies each job.
# A job is picked when a PICKED line follows its DONE line, or when a
# <name>.picked marker file exists in the logs directory.
#
# Output is machine-readable:
#   JOB name=<name> state=<RUNNING|DONE-UNPICKED|STUCK> age_seconds=<n>
#   SUMMARY ... STATE=<IDLE|RUNNING|DONE-UNPICKED|STUCK>
#
# Exit status: 0 for IDLE/RUNNING, 1 for DONE-UNPICKED/STUCK.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: watchdog.sh [--dir LOG_DIR] [--threshold-minutes N] [--max-hours N]

  --dir LOG_DIR            directory containing <name>-progress.log
                           (default: SLIPWAY_LOG_DIR, then SLIPWAY_HOME,
                           then ~/.slipway)
  --threshold-minutes N    a START with no DONE older than N minutes is STUCK
                           (default: SLIPWAY_STUCK_MINUTES, then 180)
  --max-hours N            a run longer than N hours is STUCK
                           (default: SLIPWAY_MAX_HOURS, then 3)
EOF
}

fail() {
  printf 'watchdog.sh: %s\n' "$*" >&2
  exit 2
}

LOG_DIR="${SLIPWAY_LOG_DIR:-${SLIPWAY_HOME:-$HOME/.slipway}}"
THRESHOLD_MIN="${SLIPWAY_STUCK_MINUTES:-180}"
MAX_HOURS="${SLIPWAY_MAX_HOURS:-3}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || fail "--dir needs a value"
      LOG_DIR="$2"; shift 2
      ;;
    --threshold-minutes)
      [ "$#" -ge 2 ] || fail "--threshold-minutes needs a value"
      THRESHOLD_MIN="$2"; shift 2
      ;;
    --max-hours)
      [ "$#" -ge 2 ] || fail "--max-hours needs a value"
      MAX_HOURS="$2"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      fail "unknown argument: $1 (try --help)"
      ;;
  esac
done

case "$THRESHOLD_MIN" in
  ''|*[!0-9]*) fail "--threshold-minutes must be a non-negative integer" ;;
esac
case "$MAX_HOURS" in
  ''|*[!0-9]*) fail "--max-hours must be a non-negative integer" ;;
esac

threshold_sec=$((THRESHOLD_MIN * 60))
max_sec=$((MAX_HOURS * 3600))
now="$(date -u +%s)"

to_epoch() {
  date -u -d "$1" +%s 2>/dev/null
}

shopt -s nullglob
files=("$LOG_DIR"/*-progress.log)

count_running=0
count_done=0
count_stuck=0
count_idle=0

if [ "${#files[@]}" -eq 0 ]; then
  printf 'SUMMARY IDLE=0 RUNNING=0 DONE-UNPICKED=0 STUCK=0 TOTAL=0 STATE=IDLE\n'
  exit 0
fi

for file in "${files[@]}"; do
  base="${file##*/}"
  name="${base%-progress.log}"

  last_event=""
  last_ts=""

  while IFS= read -r line || [ -n "$line" ]; do
    read -r ts event _ <<< "$line"
    case "${event:-}" in
      START|DONE|PICKED)
        if [ -n "${ts:-}" ] && to_epoch "$ts" >/dev/null 2>&1; then
          last_event="$event"
          last_ts="$ts"
        fi
        ;;
    esac
  done < "$file"

  if [ -z "$last_event" ]; then
    continue
  fi

  if [ "$last_event" = "DONE" ] && [ -e "$LOG_DIR/$name.picked" ]; then
    last_event="PICKED"
  fi

  last_epoch="$(to_epoch "$last_ts")"
  age=$((now - last_epoch))
  if [ "$age" -lt 0 ]; then
    age=0
  fi

  case "$last_event" in
    START)
      state="RUNNING"
      if [ "$age" -ge "$threshold_sec" ] || [ "$age" -gt "$max_sec" ]; then
        state="STUCK"
        count_stuck=$((count_stuck + 1))
      else
        count_running=$((count_running + 1))
      fi
      ;;
    DONE)
      state="DONE-UNPICKED"
      count_done=$((count_done + 1))
      ;;
    PICKED)
      state="IDLE"
      count_idle=$((count_idle + 1))
      ;;
    *)
      continue
      ;;
  esac

  printf 'JOB name=%s state=%s age_seconds=%s\n' "$name" "$state" "$age"
done

if [ "$count_stuck" -gt 0 ]; then
  overall="STUCK"
elif [ "$count_done" -gt 0 ]; then
  overall="DONE-UNPICKED"
elif [ "$count_running" -gt 0 ]; then
  overall="RUNNING"
else
  overall="IDLE"
fi

total=$((count_running + count_done + count_stuck + count_idle))
printf 'SUMMARY IDLE=%s RUNNING=%s DONE-UNPICKED=%s STUCK=%s TOTAL=%s STATE=%s threshold_minutes=%s max_hours=%s\n' \
  "$count_idle" "$count_running" "$count_done" "$count_stuck" "$total" "$overall" "$THRESHOLD_MIN" "$MAX_HOURS"

case "$overall" in
  STUCK|DONE-UNPICKED) exit 1 ;;
  *) exit 0 ;;
esac
