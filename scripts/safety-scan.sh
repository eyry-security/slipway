#!/usr/bin/env bash
# Pre-publication safety gate.
#
# Two scans:
#   1. secrets: key/token/password assignments, private key blocks, known token
#      prefixes, URLs with inline credentials, and env files tracked by git.
#      Scans the working tree AND git history.
#   2. banned terms: read from an EXTERNAL file passed with --terms. The terms
#      list itself never lives in the repository.
#
# The report records locations and rule names only. It never copies a secret
# value or a banned term into the report.
#
# Exit status: 0 clean, 1 any hit, 2 usage/input error.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: safety-scan.sh --terms FILE [--repo DIR] [--report FILE]

  --terms FILE     external file with one banned term per line
                   (blank lines and # comments are ignored; required)
  --repo DIR       repository tree to scan (default: current directory)
  --report FILE    output report (default: ./safety-scan-report.txt)

Exit status: 0 clean, 1 any hit, 2 usage/input error.
EOF
}

fail() {
  printf 'safety-scan.sh: %s\n' "$*" >&2
  exit 2
}

REPO="$PWD"
TERMS=""
REPORT="./safety-scan-report.txt"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --terms)
      [ "$#" -ge 2 ] || fail "--terms needs a value"
      TERMS="$2"; shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || fail "--repo needs a value"
      REPO="$2"; shift 2
      ;;
    --report)
      [ "$#" -ge 2 ] || fail "--report needs a value"
      REPORT="$2"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      fail "unknown argument: $1 (try --help)"
      ;;
  esac
done

[ -n "$TERMS" ] || fail "--terms FILE is required and must live outside the repo"
[ -f "$TERMS" ] || fail "terms file not found: $TERMS"
[ -r "$TERMS" ] || fail "terms file not readable: $TERMS"
[ -d "$REPO" ] || fail "repo directory not found: $REPO"

report_dir="$(dirname "$REPORT")"
[ -d "$report_dir" ] || mkdir -p "$report_dir"

: > "$REPORT"

HITS=0
add_hit() {
  printf '%s\n' "$*" >> "$REPORT"
  HITS=$((HITS + 1))
}

IS_GIT=0
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=1
fi

EXCLUDES=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=target)

case "$REPORT" in
  "$REPO"/*) EXCLUDES+=(--exclude="$(basename "$REPORT")") ;;
esac
case "$TERMS" in
  "$REPO"/*) EXCLUDES+=(--exclude="$(basename "$TERMS")") ;;
esac

# Case-insensitive, extended. Keep labels short so the report stays readable.
SECRET_PATTERNS=(
  "private-key-block|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "credential-assignment|(api[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key|client[_-]?secret|auth[_-]?token|access[_-]?token|refresh[_-]?token|password|passwd)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9/+_.=-]{8,}"
  "token-prefix|(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|do[op]_v1_[a-f0-9]{64})"
  "url-credentials|https?://[^/[:space:]@]+:[^/[:space:]@]+@"
)

{
  printf '# Slipway safety scan\n'
  printf 'repo: %s\n' "$REPO"
  printf 'git_history: %s\n' "$IS_GIT"
  printf 'terms_file: external (contents not copied)\n'
  printf 'started: %s\n\n' "$(date -u +%FT%TZ)"
} >> "$REPORT"

scan_tree_pattern() {
  local label="$1"
  local pattern="$2"
  local output loc

  output="$(grep -RIniE "${EXCLUDES[@]}" -e "$pattern" "$REPO" 2>/dev/null \
    | awk -F: '{print $1":"$2}' || true)"

  if [ -n "$output" ]; then
    while IFS= read -r loc; do
      add_hit "SECRET $label $loc"
    done <<< "$output"
  fi
}

scan_history_pattern() {
  local label="$1"
  local pattern="$2"

  [ "$IS_GIT" -eq 1 ] || return 0

  # Do not use grep -q here: early exit can SIGPIPE git and trip pipefail.
  if git -C "$REPO" log -p --all --no-color 2>/dev/null \
    | grep -Ei -e "$pattern" >/dev/null; then
    add_hit "SECRET $label git-history"
  fi
}

scan_tracked_env_files() {
  local file base

  [ "$IS_GIT" -eq 1 ] || return 0

  while IFS= read -r file; do
    case "$file" in
      *.example|*.sample|*.tmpl) continue ;;
    esac
    base="${file##*/}"
    case "$base" in
      .env|.env.*|*.env|agent-env|agent-env.*)
        add_hit "TRACKED-ENV $file"
        ;;
    esac
  done < <(git -C "$REPO" ls-files)
}

for entry in "${SECRET_PATTERNS[@]}"; do
  label="${entry%%|*}"
  pattern="${entry#*|}"
  scan_tree_pattern "$label" "$pattern"
  scan_history_pattern "$label" "$pattern"
done

scan_tracked_env_files

term_index=0
while IFS= read -r term || [ -n "$term" ]; do
  term="${term%$'\r'}"
  case "$term" in
    ''|'#'*) continue ;;
  esac
  term_index=$((term_index + 1))

  output="$(grep -RIniF "${EXCLUDES[@]}" -e "$term" "$REPO" 2>/dev/null \
    | awk -F: '{print $1":"$2}' || true)"
  if [ -n "$output" ]; then
    while IFS= read -r loc; do
      add_hit "BANNED-TERM term=$term_index $loc"
    done <<< "$output"
  fi

  if [ "$IS_GIT" -eq 1 ] \
    && git -C "$REPO" log -p --all --no-color 2>/dev/null | grep -Fi -e "$term" >/dev/null; then
    add_hit "BANNED-TERM term=$term_index git-history"
  fi
done < "$TERMS"

{
  printf '\nfinished: %s\n' "$(date -u +%FT%TZ)"
  if [ "$HITS" -gt 0 ]; then
    printf 'RESULT FAIL hits=%s\n' "$HITS"
  else
    printf 'RESULT CLEAN hits=0\n'
  fi
} >> "$REPORT"

if [ "$HITS" -gt 0 ]; then
  printf 'safety-scan.sh: FAIL (%s hit(s)); see %s\n' "$HITS" "$REPORT" >&2
  exit 1
fi

printf 'safety-scan.sh: clean; see %s\n' "$REPORT"
