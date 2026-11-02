#!/usr/bin/env bash
# Slipway fresh-image bootstrap (cloud-init user-data).
#
# Installs Node 22 and a pinned OpenCode, clones the repos named in a config
# file, and creates a 0600 agent-env skeleton with placeholders.
#
# Render or include this file as user-data, and provide the config files
# described in provision/README.md. Everything below is overridable from the
# environment used to render the user-data.

set -euo pipefail

SLIPWAY_USER="${SLIPWAY_USER:-root}"
SLIPWAY_CONFIG_DIR="${SLIPWAY_CONFIG_DIR:-/etc/slipway}"
SLIPWAY_WORKSPACE="${SLIPWAY_WORKSPACE:-/opt/slipway/workspace}"
SLIPWAY_REPOS_FILE="${SLIPWAY_REPOS_FILE:-$SLIPWAY_CONFIG_DIR/repos.conf}"
SLIPWAY_ENV_TARGET="${SLIPWAY_ENV_TARGET:-$SLIPWAY_CONFIG_DIR/agent-env}"
SLIPWAY_NODE_MAJOR="${SLIPWAY_NODE_MAJOR:-22}"
SLIPWAY_OPENCODE_VERSION="${SLIPWAY_OPENCODE_VERSION:-1.19.4}"
SLIPWAY_LOG="${SLIPWAY_LOG:-/var/log/slipway-bootstrap.log}"

mkdir -p "$(dirname "$SLIPWAY_LOG")"
exec > >(tee -a "$SLIPWAY_LOG") 2>&1

log() {
  printf '[slipway-bootstrap] %s\n' "$*"
}

log "starting"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git jq unzip

# --- Node 22 ----------------------------------------------------------------

node_major() {
  if command -v node >/dev/null 2>&1; then
    node --version | sed 's/^v//' | cut -d. -f1
  else
    printf '0'
  fi
}

if [ "$(node_major)" != "$SLIPWAY_NODE_MAJOR" ]; then
  log "installing Node ${SLIPWAY_NODE_MAJOR}"
  curl -fsSL "https://deb.nodesource.com/setup_${SLIPWAY_NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
else
  log "Node $(node --version) already installed"
fi

# --- pinned OpenCode --------------------------------------------------------

if ! command -v opencode >/dev/null 2>&1 \
  || [ "$(opencode --version 2>/dev/null || true)" != "$SLIPWAY_OPENCODE_VERSION" ]; then
  log "installing opencode-ai@${SLIPWAY_OPENCODE_VERSION}"
  npm install -g "opencode-ai@${SLIPWAY_OPENCODE_VERSION}"
else
  log "OpenCode ${SLIPWAY_OPENCODE_VERSION} already installed"
fi

# --- workspace + repos ------------------------------------------------------

mkdir -p "$SLIPWAY_WORKSPACE"
chmod 755 "$SLIPWAY_WORKSPACE"

if [ ! -f "$SLIPWAY_REPOS_FILE" ]; then
  mkdir -p "$(dirname "$SLIPWAY_REPOS_FILE")"
  cat > "$SLIPWAY_REPOS_FILE" <<'EOF'
# Slipway repos config: <name> <git-url> [branch]
# Keep real repository URLs and hostnames outside this repository.
# builder-repo git@example.com:org/repo.git main
EOF
  chmod 600 "$SLIPWAY_REPOS_FILE"
  log "no repos config at $SLIPWAY_REPOS_FILE; wrote a skeleton"
else
  while IFS=$' \t' read -r name url branch _; do
    case "$name" in
      ''|'#'*) continue ;;
    esac
    if [ -z "$url" ]; then
      log "skipping repo line with no url: $name"
      continue
    fi
    target="$SLIPWAY_WORKSPACE/$name"
    if [ -d "$target/.git" ]; then
      log "updating $name"
      git -C "$target" fetch --all --prune
    else
      log "cloning $name"
      if [ -n "$branch" ]; then
        git clone --branch "$branch" -- "$url" "$target"
      else
        git clone -- "$url" "$target"
      fi
    fi
  done < "$SLIPWAY_REPOS_FILE"
fi

# --- agent-env skeleton (0600, placeholders) --------------------------------

mkdir -p "$SLIPWAY_CONFIG_DIR"
chmod 700 "$SLIPWAY_CONFIG_DIR"

if [ ! -f "$SLIPWAY_ENV_TARGET" ]; then
  umask 077
  cat > "$SLIPWAY_ENV_TARGET" <<'EOF'
# Slipway agent environment. Fill these in before dispatch.
# Keep this file outside git and mode 0600.
DEEPSEEK_API_KEY=
OPENCODE_SERVER_PASSWORD=
EOF
  log "wrote agent-env skeleton at $SLIPWAY_ENV_TARGET"
else
  log "agent-env already exists at $SLIPWAY_ENV_TARGET"
fi
chmod 600 "$SLIPWAY_ENV_TARGET"

if [ "$SLIPWAY_USER" != "root" ]; then
  if id "$SLIPWAY_USER" >/dev/null 2>&1; then
    chown -R "$SLIPWAY_USER" "$SLIPWAY_WORKSPACE"
    chown "$SLIPWAY_USER" "$SLIPWAY_ENV_TARGET"
    log "chowned workspace and agent-env to $SLIPWAY_USER"
  else
    log "warning: user $SLIPWAY_USER does not exist; leaving files root-owned"
  fi
fi

touch "$SLIPWAY_CONFIG_DIR/bootstrap.done"
log "done"
