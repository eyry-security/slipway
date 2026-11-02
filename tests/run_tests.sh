#!/usr/bin/env bash
# Slipway test suite. No network, no real secrets, no real hosts.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() {
  printf 'ok   %s\n' "$1"
  PASS=$((PASS + 1))
}

bad() {
  printf 'FAIL %s\n' "$1"
  FAIL=$((FAIL + 1))
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/slipway-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- syntax / shellcheck ----------------------------------------------------

syntax_fail=0
while IFS= read -r -d '' script; do
  if command -v shellcheck >/dev/null 2>&1; then
    if ! shellcheck -x -S warning "$script"; then
      syntax_fail=1
    fi
  else
    if ! bash -n "$script"; then
      syntax_fail=1
    fi
  fi
done < <(find "$ROOT" -type f -name '*.sh' -not -path '*/.git/*' -print0)

if [ "$syntax_fail" -eq 0 ]; then
  ok "syntax on every script"
else
  bad "syntax on every script"
fi

# --- fixtures ---------------------------------------------------------------

FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email git@example.com
git -C "$FIXTURE" config user.name "Slipway Test"
printf 'fixture\n' > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -qm "initial"

PROMPT="$TMP/prompt.md"
printf 'Do a trivial thing and write a report.\n' > "$PROMPT"

FAKE_KEY_VALUE="FAKEKEY-test-0000"
ENVFILE="$TMP/agent-env"
printf 'DEEPSEEK_API_KEY=%s\nOPENCODE_SERVER_PASSWORD=%s\n' \
  "$FAKE_KEY_VALUE" "$FAKE_KEY_VALUE" > "$ENVFILE"
chmod 600 "$ENVFILE"

ENV_MISSING_KEY="$TMP/agent-env-missing-key"
printf 'DEEPSEEK_API_KEY=%s\n' "$FAKE_KEY_VALUE" > "$ENV_MISSING_KEY"
chmod 600 "$ENV_MISSING_KEY"

HOME_DIR="$TMP/home"

# --- run.sh dry-run ---------------------------------------------------------

out="$TMP/dry-run.out"
if SLIPWAY_HOME="$HOME_DIR" SLIPWAY_ENV_FILE="$ENVFILE" \
  "$ROOT/run.sh" --dry-run happy-job "$FIXTURE" main "$PROMPT" > "$out" 2>&1; then
  ok "run.sh --dry-run happy path exits 0"
else
  bad "run.sh --dry-run happy path exits 0"
  sed 's/^/     /' "$out"
fi

if grep -q 'DEEPSEEK_API_KEY=set' "$out" \
  && grep -q 'OPENCODE_SERVER_PASSWORD=set' "$out"; then
  ok "dry-run names required keys"
else
  bad "dry-run names required keys"
  sed 's/^/     /' "$out"
fi

if ! grep -qF "$FAKE_KEY_VALUE" "$out"; then
  ok "dry-run never prints env values"
else
  bad "dry-run never prints env values"
fi

out="$TMP/relative.out"
if SLIPWAY_HOME="$HOME_DIR" SLIPWAY_ENV_FILE="$ENVFILE" \
  "$ROOT/run.sh" --dry-run rel-job "$FIXTURE" main "prompt.md" > "$out" 2>&1; then
  bad "relative prompt path is rejected"
else
  if grep -qi 'absolute' "$out"; then
    ok "relative prompt path is rejected"
  else
    bad "relative prompt path is rejected (wrong message)"
    sed 's/^/     /' "$out"
  fi
fi

out="$TMP/missing-env.out"
if SLIPWAY_HOME="$HOME_DIR" SLIPWAY_ENV_FILE="$TMP/does-not-exist" \
  "$ROOT/run.sh" --dry-run no-env "$FIXTURE" main "$PROMPT" > "$out" 2>&1; then
  bad "missing env file is rejected"
else
  ok "missing env file is rejected"
fi

out="$TMP/missing-key.out"
if SLIPWAY_HOME="$HOME_DIR" SLIPWAY_ENV_FILE="$ENV_MISSING_KEY" \
  "$ROOT/run.sh" --dry-run no-key "$FIXTURE" main "$PROMPT" > "$out" 2>&1; then
  bad "missing env key is rejected"
else
  if grep -q 'OPENCODE_SERVER_PASSWORD' "$out" && ! grep -qF "$FAKE_KEY_VALUE" "$out"; then
    ok "missing env key is rejected without printing values"
  else
    bad "missing env key is rejected without printing values"
    sed 's/^/     /' "$out"
  fi
fi

out="$TMP/bad-branch.out"
if SLIPWAY_HOME="$HOME_DIR" SLIPWAY_ENV_FILE="$ENVFILE" \
  "$ROOT/run.sh" --dry-run bad-branch "$FIXTURE" "bad branch" "$PROMPT" > "$out" 2>&1; then
  bad "insane branch name is rejected"
else
  ok "insane branch name is rejected"
fi

# --- provisioning dry-run ---------------------------------------------------

out="$TMP/provision.out"
if "$ROOT/provision/provision.sh" --dry-run \
  --name builder-1 --image ubuntu-24-04-x64 > "$out" 2>&1; then
  ok "provision.sh --dry-run exits 0 without a token"
else
  bad "provision.sh --dry-run exits 0 without a token"
  sed 's/^/     /' "$out"
fi

if grep -q 'DRY-RUN OK' "$out" && ! grep -qi 'bearer' "$out"; then
  ok "provision dry-run prints no credentials"
else
  bad "provision dry-run prints no credentials"
fi

# --- watchdog ---------------------------------------------------------------

assert_watchdog() {
  local label="$1"
  local dir="$2"
  local expected_state="$3"
  local expected_status="$4"
  shift 4

  local out status
  out="$("$ROOT/watchdog.sh" --dir "$dir" "$@" 2>&1)"
  status=$?

  if [ "$status" -eq "$expected_status" ] && grep -q "STATE=$expected_state" <<< "$out"; then
    ok "$label"
  else
    bad "$label (status=$status expected=$expected_status)"
    sed 's/^/     /' <<< "$out"
  fi
}

WD_RUNNING="$TMP/wd-running"
mkdir -p "$WD_RUNNING"
printf '%s START job-running\n' "$(date -u +%FT%TZ)" > "$WD_RUNNING/job-running-progress.log"
assert_watchdog "watchdog classifies RUNNING" "$WD_RUNNING" RUNNING 0 --threshold-minutes 60

WD_DONE="$TMP/wd-done"
mkdir -p "$WD_DONE"
{
  printf '%s START job-done\n' "$(date -u -d '-2 minutes' +%FT%TZ)"
  printf '%s DONE job-done\n' "$(date -u +%FT%TZ)"
} > "$WD_DONE/job-done-progress.log"
assert_watchdog "watchdog classifies DONE-UNPICKED" "$WD_DONE" DONE-UNPICKED 1

touch "$WD_DONE/job-done.picked"
assert_watchdog "watchdog treats a picked DONE as IDLE" "$WD_DONE" IDLE 0

WD_STUCK="$TMP/wd-stuck"
mkdir -p "$WD_STUCK"
printf '%s START job-stuck\n' "$(date -u -d '-5 hours' +%FT%TZ)" > "$WD_STUCK/job-stuck-progress.log"
assert_watchdog "watchdog classifies STUCK" "$WD_STUCK" STUCK 1

WD_IDLE="$TMP/wd-idle"
mkdir -p "$WD_IDLE"
assert_watchdog "watchdog classifies IDLE" "$WD_IDLE" IDLE 0

# --- safety scan ------------------------------------------------------------

SAFETY="$ROOT/scripts/safety-scan.sh"
TERMS="$TMP/terms.txt"
BANNED_TERM="FORBIDDEN-TERM-test-0000"
printf '%s\n' "$BANNED_TERM" > "$TERMS"

CLEAN_REPO="$TMP/clean-repo"
mkdir -p "$CLEAN_REPO"
git -C "$CLEAN_REPO" init -q -b main
git -C "$CLEAN_REPO" config user.email git@example.com
git -C "$CLEAN_REPO" config user.name "Slipway Test"
printf 'hello world\n' > "$CLEAN_REPO/README.md"
git -C "$CLEAN_REPO" add README.md
git -C "$CLEAN_REPO" commit -qm "initial"

CLEAN_REPORT="$TMP/clean-report.txt"
if "$SAFETY" --repo "$CLEAN_REPO" --terms "$TERMS" --report "$CLEAN_REPORT" >/dev/null 2>&1; then
  ok "safety scan passes a clean tree"
else
  bad "safety scan passes a clean tree"
  sed 's/^/     /' "$CLEAN_REPORT"
fi

DIRTY_REPO="$TMP/dirty-repo"
mkdir -p "$DIRTY_REPO"
git -C "$DIRTY_REPO" init -q -b main
git -C "$DIRTY_REPO" config user.email git@example.com
git -C "$DIRTY_REPO" config user.name "Slipway Test"
printf 'notes\n' > "$DIRTY_REPO/notes.txt"
printf 'DEEPSEEK_API_KEY=%s\n' "$FAKE_KEY_VALUE" > "$DIRTY_REPO/leak.txt"
git -C "$DIRTY_REPO" add .
git -C "$DIRTY_REPO" commit -qm "fixture"

DIRTY_REPORT="$TMP/dirty-report.txt"
if "$SAFETY" --repo "$DIRTY_REPO" --terms "$TERMS" --report "$DIRTY_REPORT" >/dev/null 2>&1; then
  bad "safety scan catches a planted fake key"
else
  if grep -q 'SECRET credential-assignment' "$DIRTY_REPORT"; then
    ok "safety scan catches a planted fake key"
  else
    bad "safety scan catches a planted fake key (wrong report)"
    sed 's/^/     /' "$DIRTY_REPORT"
  fi
fi

UNTRACKED_REPO="$TMP/untracked-repo"
mkdir -p "$UNTRACKED_REPO"
git -C "$UNTRACKED_REPO" init -q -b main
git -C "$UNTRACKED_REPO" config user.email git@example.com
git -C "$UNTRACKED_REPO" config user.name "Slipway Test"
printf 'hello\n' > "$UNTRACKED_REPO/README.md"
git -C "$UNTRACKED_REPO" add README.md
git -C "$UNTRACKED_REPO" commit -qm "initial"
printf 'DEEPSEEK_API_KEY=%s\n' "$FAKE_KEY_VALUE" > "$UNTRACKED_REPO/untracked-leak.txt"

UNTRACKED_REPORT="$TMP/untracked-report.txt"
if "$SAFETY" --repo "$UNTRACKED_REPO" --terms "$TERMS" --report "$UNTRACKED_REPORT" >/dev/null 2>&1; then
  bad "safety scan catches an untracked fake key in the working tree"
else
  if grep -q 'SECRET credential-assignment' "$UNTRACKED_REPORT"; then
    ok "safety scan catches an untracked fake key in the working tree"
  else
    bad "safety scan catches an untracked fake key in the working tree (wrong report)"
    sed 's/^/     /' "$UNTRACKED_REPORT"
  fi
fi

HISTORY_REPO="$TMP/history-repo"
mkdir -p "$HISTORY_REPO"
git -C "$HISTORY_REPO" init -q -b main
git -C "$HISTORY_REPO" config user.email git@example.com
git -C "$HISTORY_REPO" config user.name "Slipway Test"
printf 'notes\n' > "$HISTORY_REPO/README.md"
printf 'DEEPSEEK_API_KEY=%s\n' "$FAKE_KEY_VALUE" > "$HISTORY_REPO/leak.txt"
git -C "$HISTORY_REPO" add .
git -C "$HISTORY_REPO" commit -qm "add fixture"
git -C "$HISTORY_REPO" rm -q leak.txt
git -C "$HISTORY_REPO" commit -qm "remove fixture"

HISTORY_REPORT="$TMP/history-report.txt"
if "$SAFETY" --repo "$HISTORY_REPO" --terms "$TERMS" --report "$HISTORY_REPORT" >/dev/null 2>&1; then
  bad "safety scan catches a secret removed from the tree but kept in history"
else
  if grep -q 'SECRET credential-assignment git-history' "$HISTORY_REPORT"; then
    ok "safety scan catches a secret removed from the tree but kept in history"
  else
    bad "safety scan catches a secret removed from the tree but kept in history (wrong report)"
    sed 's/^/     /' "$HISTORY_REPORT"
  fi
fi

BANNED_REPO="$TMP/banned-repo"
mkdir -p "$BANNED_REPO"
git -C "$BANNED_REPO" init -q -b main
git -C "$BANNED_REPO" config user.email git@example.com
git -C "$BANNED_REPO" config user.name "Slipway Test"
printf 'notes about %s\n' "$BANNED_TERM" > "$BANNED_REPO/notes.txt"
git -C "$BANNED_REPO" add notes.txt
git -C "$BANNED_REPO" commit -qm "fixture"

BANNED_REPORT="$TMP/banned-report.txt"
if "$SAFETY" --repo "$BANNED_REPO" --terms "$TERMS" --report "$BANNED_REPORT" >/dev/null 2>&1; then
  bad "safety scan catches an external banned term"
else
  if grep -q 'BANNED-TERM' "$BANNED_REPORT"; then
    ok "safety scan catches an external banned term"
  else
    bad "safety scan catches an external banned term (wrong report)"
    sed 's/^/     /' "$BANNED_REPORT"
  fi
fi

# --- summary ----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
