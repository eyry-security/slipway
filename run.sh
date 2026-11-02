#!/usr/bin/env bash
# Slipway job runner.
#
# Usage:
#   run.sh [--dry-run] <name> <repo-dir> <branch> <prompt-file-absolute>
#
# Behaviour:
#   * sources an agent environment file outside the repo
#   * optionally puts a Node/toolchain directory on PATH
#   * cuts a fresh branch from the repo's main branch
#   * runs the configured headless agent with the prompt file's contents
#   * appends START/DONE markers to <name>-progress.log
#   * expects the agent to leave <name>-report.md in SLIPWAY_HOME
#
# Everything that is deployment-specific is an environment input. The runner
# never prints environment values.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: run.sh [--dry-run] <name> <repo-dir> <branch> <prompt-file-absolute>

  --dry-run    validate inputs and print the resolved configuration, then exit
               without sourcing secrets or launching anything.

environment:
  SLIPWAY_HOME         logs/reports directory (default: ~/.slipway)
  SLIPWAY_ENV_FILE     agent env file (default: ~/.config/slipway/agent-env)
  SLIPWAY_ENV_KEYS     required env keys, space separated
                       (default: DEEPSEEK_API_KEY OPENCODE_SERVER_PASSWORD)
  SLIPWAY_NODE_BIN     optional directory to prepend to PATH
  SLIPWAY_AGENT_CMD    headless agent command (default: opencode run --auto)

The prompt path must be absolute. Relative prompt paths are rejected.
EOF
}

fail() {
  printf 'run.sh: %s\n' "$*" >&2
  exit 1
}

is_absolute() {
  case "$1" in
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      fail "unknown option: $1 (try --help)"
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -ne 4 ]; then
  usage >&2
  exit 2
fi

NAME="$1"
REPO="$2"
BRANCH="$3"
PROMPT="$4"

SLIPWAY_HOME="${SLIPWAY_HOME:-$HOME/.slipway}"
SLIPWAY_ENV_FILE="${SLIPWAY_ENV_FILE:-$HOME/.config/slipway/agent-env}"
SLIPWAY_ENV_KEYS="${SLIPWAY_ENV_KEYS:-DEEPSEEK_API_KEY OPENCODE_SERVER_PASSWORD}"
SLIPWAY_NODE_BIN="${SLIPWAY_NODE_BIN:-}"
SLIPWAY_AGENT_CMD="${SLIPWAY_AGENT_CMD:-opencode run --auto}"

PROGRESS_LOG="$SLIPWAY_HOME/$NAME-progress.log"
RUN_LOG="$SLIPWAY_HOME/$NAME.runlog"
REPORT_FILE="$SLIPWAY_HOME/$NAME-report.md"

# --- input validation -------------------------------------------------------

case "$NAME" in
  ''|*[!A-Za-z0-9._-]*|.*)
    fail "name must be a simple slug (letters, digits, '.', '_', '-'): $NAME"
    ;;
esac

if ! is_absolute "$PROMPT"; then
  fail "prompt path must be absolute: $PROMPT"
fi

[ -f "$PROMPT" ] || fail "prompt file not found: $PROMPT"
[ -r "$PROMPT" ] || fail "prompt file not readable: $PROMPT"

[ -d "$REPO" ] || fail "repo directory not found: $REPO"

if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "repo directory is not a git work tree: $REPO"
fi

if ! git -C "$REPO" rev-parse --verify --quiet main >/dev/null 2>&1; then
  fail "repo has no 'main' branch to cut from: $REPO"
fi

case "$BRANCH" in
  -*) fail "branch name must not start with '-': $BRANCH" ;;
esac
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
  || fail "branch name is not a valid git ref: $BRANCH"

[ -f "$SLIPWAY_ENV_FILE" ] || fail "env file not found: $SLIPWAY_ENV_FILE"
[ -r "$SLIPWAY_ENV_FILE" ] || fail "env file not readable: $SLIPWAY_ENV_FILE"

env_key_present() {
  local key="$1"
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*[^[:space:]#]+" \
    "$SLIPWAY_ENV_FILE"
}

missing_keys=()
for key in $SLIPWAY_ENV_KEYS; do
  env_key_present "$key" || missing_keys+=("$key")
done

if [ "${#missing_keys[@]}" -gt 0 ]; then
  fail "env file is missing required keys: ${missing_keys[*]} (values are never printed)"
fi

[ -n "$SLIPWAY_AGENT_CMD" ] || fail "SLIPWAY_AGENT_CMD is empty"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY-RUN name=%s\n' "$NAME"
  printf '  repo=%s\n' "$REPO"
  printf '  branch=%s (from main)\n' "$BRANCH"
  printf '  prompt=%s\n' "$PROMPT"
  printf '  home=%s\n' "$SLIPWAY_HOME"
  printf '  env_file=%s\n' "$SLIPWAY_ENV_FILE"
  for key in $SLIPWAY_ENV_KEYS; do
    printf '  env_key=%s=set\n' "$key"
  done
  if [ -n "$SLIPWAY_NODE_BIN" ]; then
    printf '  node_bin=%s\n' "$SLIPWAY_NODE_BIN"
  else
    printf '  node_bin=(PATH unchanged)\n'
  fi
  printf '  agent_cmd=%s\n' "$SLIPWAY_AGENT_CMD"
  printf '  progress_log=%s\n' "$PROGRESS_LOG"
  printf '  run_log=%s\n' "$RUN_LOG"
  printf '  report=%s\n' "$REPORT_FILE"
  printf 'DRY-RUN OK (nothing sourced, nothing launched)\n'
  exit 0
fi

# --- live run ---------------------------------------------------------------

mkdir -p "$SLIPWAY_HOME"
[ -w "$SLIPWAY_HOME" ] || fail "home directory is not writable: $SLIPWAY_HOME"

set -a
# shellcheck source=/dev/null
source "$SLIPWAY_ENV_FILE"
set +a

if [ -n "$SLIPWAY_NODE_BIN" ]; then
  export PATH="$SLIPWAY_NODE_BIN:$PATH"
fi

read -r -a AGENT_CMD <<< "$SLIPWAY_AGENT_CMD"
[ "${#AGENT_CMD[@]}" -gt 0 ] || fail "SLIPWAY_AGENT_CMD did not parse to a command"
command -v "${AGENT_CMD[0]}" >/dev/null 2>&1 \
  || fail "agent command not found on PATH: ${AGENT_CMD[0]}"

stamp() {
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$1" "$NAME" >> "$PROGRESS_LOG"
}

stamp START

if ! git -C "$REPO" checkout -B "$BRANCH" main >> "$PROGRESS_LOG" 2>&1; then
  stamp DONE
  fail "git checkout failed; see $PROGRESS_LOG"
fi

PROMPT_TEXT="$(cat "$PROMPT")"

set +e
(
  cd "$REPO"
  "${AGENT_CMD[@]}" "$PROMPT_TEXT" > "$RUN_LOG" 2>&1
)
AGENT_STATUS=$?
set -e

stamp DONE

if [ "$AGENT_STATUS" -ne 0 ]; then
  printf 'run.sh: agent exited %s; see %s\n' "$AGENT_STATUS" "$RUN_LOG" >&2
  exit "$AGENT_STATUS"
fi

if [ ! -f "$REPORT_FILE" ]; then
  printf 'run.sh: agent finished but expected report is missing: %s\n' "$REPORT_FILE" >&2
  exit 3
fi

printf 'run.sh: done: %s -> %s\n' "$NAME" "$REPORT_FILE"
