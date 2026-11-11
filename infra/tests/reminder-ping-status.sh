#!/usr/bin/env bash
# Reminder ping URL check in infra/converge.sh status. Sources the script for its
# functions, points the check at a scratch file, and stubs stat for owner and
# mode. Covers staging (skipped), and on production: missing, wrong owner or
# mode, empty, and good. The URL itself must never reach the output.
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$TESTS_DIR")"
FAILURES=0

# shellcheck source=infra/converge.sh
source "${INFRA_DIR}/converge.sh"

SCRATCH="$(mktemp -d)"
trap 'command rm -rf "$SCRATCH"' EXIT
REMINDER_PING_URL_FILE="${SCRATCH}/reminder-ping-url"
PING_URL='https://ping.invalid/secret-check-id'
OWNER_MODE=''

# The stub shadows stat: '%U:%G %a' gives the test's owner and mode; file_facts
# also gets a size, read from the real file.
# shellcheck disable=SC2329
stat() {
  local size
  size="$(wc -c < "$3" | tr -d ' ')"
  case "$2" in
    '%U:%G %a') printf '%s\n' "$OWNER_MODE" ;;
    *) printf '%s %sB\n' "$OWNER_MODE" "$size" ;;
  esac
}

reset_manual_state() {
  MANUAL_LINES=()
  MANUAL_FAILED=0
  MANUAL_WARNED=0
}

# expect <pattern> <failed> <warned>: the one line matches, with these counts,
# and no line holds the URL.
expect() {
  local line="${MANUAL_LINES[0]:-}"
  if [[ "$line" =~ $1 && "$MANUAL_FAILED" -eq "$2" && "$MANUAL_WARNED" -eq "$3" \
    && "$line" != *"$PING_URL"* && ${#MANUAL_LINES[@]} -eq 1 ]]; then
    printf 'ok    %s\n' "$line"
  else
    printf 'FAIL  want /%s/ (%d failed, %d warned), got: %s (%d failed, %d warned)\n' \
      "$1" "$2" "$3" "${line:-nothing}" "$MANUAL_FAILED" "$MANUAL_WARNED"
    FAILURES=$((FAILURES + 1))
  fi
}

printf '== staging\n'
reset_manual_state
check_reminder_ping staging
expect '^  skip +reminder ping +not checked' 0 0

printf '== production, missing\n'
reset_manual_state
check_reminder_ping production
expect '^  WARN +reminder ping .* missing: a stopped reminder job alerts no one$' 0 1

printf '== production, wrong owner and mode\n'
printf '%s\n' "$PING_URL" > "$REMINDER_PING_URL_FILE"
OWNER_MODE='root:root 644'
reset_manual_state
check_reminder_ping production
expect '^  WARN +reminder ping .* root:root 644 [0-9]+B; should be root:www-data 640$' 0 1

printf '== production, empty\n'
: > "$REMINDER_PING_URL_FILE"
OWNER_MODE='root:www-data 640'
reset_manual_state
check_reminder_ping production
expect '^  WARN +reminder ping .* root:www-data 640 0B, empty: the job pings nothing$' 0 1

printf '== production, good\n'
printf '%s\n' "$PING_URL" > "$REMINDER_PING_URL_FILE"
reset_manual_state
check_reminder_ping production
expect '^  ok +reminder ping .* root:www-data 640 [0-9]+B$' 0 0

printf '== %d failure(s)\n' "$FAILURES"
exit "$FAILURES"
