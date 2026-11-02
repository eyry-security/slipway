#!/usr/bin/env bash
# Create a DigitalOcean droplet from a snapshot or a stock image.
#
# The API token is read from the environment at call time. It is never written
# to a file, never placed in the process arguments, and never printed.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: provision.sh --name NAME (--snapshot ID | --image SLUG) [options]

options:
  --name NAME          droplet name (required)
  --snapshot ID        boot from a snapshot id
  --image SLUG         boot from a stock image (mutually exclusive with --snapshot)
  --region REGION      default: nyc3
  --size SIZE          default: s-2vcpu-4gb
  --ssh-keys "A B"     space-separated SSH key ids or fingerprints
  --tag TAG            add a tag (repeatable)
  --user-data FILE     cloud-init/user-data file
  --wait               wait for the droplet to become active, then print its IP
  --timeout SECONDS    wait timeout, default: 600
  --dry-run            print the request shape without calling the API
  -h, --help           show this help

token:
  DO_API_TOKEN or DIGITALOCEAN_TOKEN must be set in the environment. Values are
  never stored or echoed.

examples:
  provision.sh --name builder-1 --image ubuntu-24-04-x64 \
      --user-data provision/user-data/bootstrap.sh --wait

  provision.sh --name builder-2 --snapshot SNAPSHOT_ID \
      --user-data provision/user-data/strip-clone.sh --wait
EOF
}

die() {
  printf 'provision.sh: %s\n' "$*" >&2
  exit 1
}

NAME=""
SNAPSHOT=""
IMAGE=""
REGION="${DO_REGION:-nyc3}"
SIZE="${DO_SIZE:-s-2vcpu-4gb}"
SSH_KEYS="${DO_SSH_KEYS:-}"
USER_DATA=""
WAIT=0
TIMEOUT="${DO_WAIT_TIMEOUT:-600}"
DRY_RUN=0
TAGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)
      [ "$#" -ge 2 ] || die "--name needs a value"
      NAME="$2"; shift 2
      ;;
    --snapshot)
      [ "$#" -ge 2 ] || die "--snapshot needs a value"
      SNAPSHOT="$2"; shift 2
      ;;
    --image)
      [ "$#" -ge 2 ] || die "--image needs a value"
      IMAGE="$2"; shift 2
      ;;
    --region)
      [ "$#" -ge 2 ] || die "--region needs a value"
      REGION="$2"; shift 2
      ;;
    --size)
      [ "$#" -ge 2 ] || die "--size needs a value"
      SIZE="$2"; shift 2
      ;;
    --ssh-keys)
      [ "$#" -ge 2 ] || die "--ssh-keys needs a value"
      SSH_KEYS="$2"; shift 2
      ;;
    --tag)
      [ "$#" -ge 2 ] || die "--tag needs a value"
      TAGS+=("$2"); shift 2
      ;;
    --user-data)
      [ "$#" -ge 2 ] || die "--user-data needs a value"
      USER_DATA="$2"; shift 2
      ;;
    --wait)
      WAIT=1; shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || die "--timeout needs a value"
      TIMEOUT="$2"; shift 2
      ;;
    --dry-run)
      DRY_RUN=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

[ -n "$NAME" ] || die "--name is required"

if [ -n "$SNAPSHOT" ] && [ -n "$IMAGE" ]; then
  die "use either --snapshot or --image, not both"
fi

if [ -z "$SNAPSHOT" ] && [ -z "$IMAGE" ]; then
  IMAGE="ubuntu-24-04-x64"
fi

if [ -n "$USER_DATA" ]; then
  [ -f "$USER_DATA" ] || die "user-data file not found: $USER_DATA"
  [ -r "$USER_DATA" ] || die "user-data file not readable: $USER_DATA"
fi

case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be an integer number of seconds" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required for JSON handling"

workdir="$(mktemp -d)"
payload="$workdir/payload.json"
response="$workdir/response.json"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

chmod 700 "$workdir"

python3 - "$payload" "$NAME" "$REGION" "$SIZE" "$SNAPSHOT" "$IMAGE" "$SSH_KEYS" "$USER_DATA" "${TAGS[@]}" <<'PY'
import json
import sys

path, name, region, size, snapshot, image, ssh_keys, user_data, *tags = sys.argv[1:]
body = {
    "name": name,
    "region": region,
    "size": size,
    "tags": tags,
}
if snapshot:
    body["snapshot_id"] = snapshot
else:
    body["image"] = image
if ssh_keys:
    body["ssh_keys"] = ssh_keys.split()
if user_data:
    with open(user_data, "r", encoding="utf-8") as handle:
        body["user_data"] = handle.read()

with open(path, "w", encoding="utf-8") as handle:
    json.dump(body, handle)
PY

chmod 600 "$payload"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY-RUN droplet name=%s region=%s size=%s\n' "$NAME" "$REGION" "$SIZE"
  if [ -n "$SNAPSHOT" ]; then
    printf '  snapshot=%s\n' "$SNAPSHOT"
  else
    printf '  image=%s\n' "$IMAGE"
  fi
  printf '  tags=%s\n' "${TAGS[*]:-}"
  if [ -n "$SSH_KEYS" ]; then
    printf '  ssh_keys=%s\n' "$(printf '%s' "$SSH_KEYS" | wc -w | tr -d ' ')"
  else
    printf '  ssh_keys=0\n'
  fi
  if [ -n "$USER_DATA" ]; then
    printf '  user_data=%s bytes=%s\n' "$USER_DATA" "$(wc -c < "$USER_DATA" | tr -d ' ')"
  else
    printf '  user_data=(none)\n'
  fi
  printf '  token=(not used in dry-run)\n'
  printf 'DRY-RUN OK (no API call)\n'
  exit 0
fi

DO_TOKEN="${DO_API_TOKEN:-${DIGITALOCEAN_TOKEN:-}}"
if [ -z "$DO_TOKEN" ]; then
  die "set DO_API_TOKEN (or DIGITALOCEAN_TOKEN) in the environment"
fi

# Send the bearer token through stdin so it does not appear in the process
# arguments. Request metadata stays in a mode-600 temporary file.
api_post() {
  curl --silent --show-error \
    --request POST \
    --header @- \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload" \
    --output "$response" \
    --write-out '%{http_code}' \
    https://api.digitalocean.com/v2/droplets <<EOF
Authorization: Bearer $DO_TOKEN
EOF
}

api_get() {
  local url="$1"
  curl --silent --show-error \
    --header @- \
    --output "$response" \
    --write-out '%{http_code}' \
    "$url" <<EOF
Authorization: Bearer $DO_TOKEN
EOF
}

HTTP_CODE="$(api_post)"

if [ "$HTTP_CODE" != "202" ] && [ "$HTTP_CODE" != "201" ]; then
  MESSAGE="$(python3 - "$response" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
    print(data.get("message", "unknown API error"))
except Exception:
    print("unreadable API response")
PY
)"
  die "DigitalOcean API returned HTTP $HTTP_CODE: $MESSAGE"
fi

DROPLET_ID="$(python3 - "$response" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
print(data["droplet"]["id"])
PY
)"

[ -n "$DROPLET_ID" ] || die "API response did not contain a droplet id"

DROPLET_IP=""

if [ "$WAIT" -eq 1 ]; then
  elapsed=0
  STATUS="unknown"
  while [ "$elapsed" -lt "$TIMEOUT" ]; do
    HTTP_CODE="$(api_get "https://api.digitalocean.com/v2/droplets/$DROPLET_ID")"
    if [ "$HTTP_CODE" != "200" ]; then
      die "droplet lookup returned HTTP $HTTP_CODE"
    fi
    STATUS_IP="$(python3 - "$response" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    droplet = json.load(handle)["droplet"]
networks = droplet.get("networks", {}).get("v4", [])
address = next((n.get("ip_address", "") for n in networks if n.get("type") == "public"), "")
print(droplet.get("status", "unknown"), address)
PY
)"
    read -r STATUS DROPLET_IP <<< "$STATUS_IP"
    if [ "$STATUS" = "active" ]; then
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [ "$STATUS" != "active" ]; then
    die "droplet $DROPLET_ID did not become active within ${TIMEOUT}s"
  fi
fi

printf 'DROPLET_ID=%s\n' "$DROPLET_ID"
printf 'DROPLET_NAME=%s\n' "$NAME"
if [ -n "$DROPLET_IP" ]; then
  printf 'DROPLET_IP=%s\n' "$DROPLET_IP"
else
  printf 'DROPLET_IP=(pending; rerun with --wait)\n'
fi
