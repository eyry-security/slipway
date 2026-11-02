#!/usr/bin/env bash
# Slipway snapshot-clone strip step (cloud-init user-data).
#
# A snapshot can contain live production services. This script disables and
# stops the named systemd units listed in an external config file so a clone
# cannot keep serving production traffic.
#
# Config format (one unit per line, blank lines and # comments ignored):
#   example-api.service
#   example-worker.service
#
# Keep the real unit list outside this repository.

set -euo pipefail

SLIPWAY_SERVICES_FILE="${SLIPWAY_SERVICES_FILE:-/etc/slipway/production-services.conf}"
SLIPWAY_LOG="${SLIPWAY_LOG:-/var/log/slipway-strip-clone.log}"

mkdir -p "$(dirname "$SLIPWAY_LOG")"
exec > >(tee -a "$SLIPWAY_LOG") 2>&1

log() {
  printf '[slipway-strip-clone] %s\n' "$*"
}

log "starting"

if [ ! -f "$SLIPWAY_SERVICES_FILE" ]; then
  log "ERROR: services config not found: $SLIPWAY_SERVICES_FILE"
  log "refusing to continue without an explicit production service list"
  exit 1
fi

failed=0
count=0

while IFS= read -r unit || [ -n "$unit" ]; do
  unit="${unit%%#*}"
  unit="$(printf '%s' "$unit" | tr -d '[:space:]')"
  case "$unit" in
    ''|'#'*) continue ;;
  esac

  case "$unit" in
    *[!A-Za-z0-9@_.:-]*)
      log "ERROR: refusing suspicious unit name: $unit"
      failed=1
      continue
      ;;
  esac

  count=$((count + 1))
  if systemctl disable --now "$unit"; then
    log "disabled and stopped $unit"
  else
    log "ERROR: could not disable/stop $unit"
    failed=1
  fi
done < "$SLIPWAY_SERVICES_FILE"

if [ "$count" -eq 0 ]; then
  log "warning: service list is empty; nothing was stopped"
fi

if [ "$failed" -ne 0 ]; then
  log "finished with errors"
  exit 1
fi

log "done ($count unit(s))"
