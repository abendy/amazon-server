#!/usr/bin/env bash
# Time zone checks in infra/converge.sh status. Sources the script for its
# functions, stubs timedatectl, php and php-fpm8.4, and runs the checks twice:
#   1. all UTC: host Etc/UTC, PHP UTC, databases +00:00 or SYSTEM over UTC
#   2. drifted: host and FPM on Pacific time, one database Pacific, one
#      unreadable
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$TESTS_DIR")"
FAILURES=0

# shellcheck source=infra/converge.sh
source "${INFRA_DIR}/converge.sh"

HOST_ZONE=''
CLI_ZONE=''
FPM_ZONE=''
declare -A DB_REPLY=()

# The stubs below shadow the real commands that converge.sh calls.
# shellcheck disable=SC2329
timedatectl() { printf '%s\n' "$HOST_ZONE"; }
# php -r prints the CLI zone; php -- <kind> <path> is the database probe.
# shellcheck disable=SC2329
php() {
  local arg kind='' path=''
  while [[ $# -gt 0 ]]; do
    arg="$1"
    shift
    case "$arg" in
      -r) printf '%s' "$CLI_ZONE"; return 0 ;;
      --) kind="$1"; path="$2"; break ;;
    esac
  done
  cat > /dev/null
  printf '%s\n' "${DB_REPLY[${kind}:${path}]:-}"
}
# shellcheck disable=SC2329
php-fpm8.4() { printf 'date.timezone => %s => %s\n' "$FPM_ZONE" "$FPM_ZONE"; }

PHP_SETTING=([rsvp_version]=8.4 [ampas_version]=8.4 [guilds_version]=8.4 [cli_version]=8.4)
RSVP_DB="${RSVP_ROOT}/admin/application/config/staging/database.php"

reset_zone_state() {
  ZONE_LINES=()
  ZONE_PROBLEMS=()
  ZONE_WARNED=0
}

# expect <label> <pattern>: the ZONE_LINES entry for the label matches the pattern.
expect() {
  local line
  line="$(printf '%s\n' "${ZONE_LINES[@]}" | grep -E "^  [a-zA-Z]+ +${1} " || true)"
  if [[ "$line" =~ $2 ]]; then
    printf 'ok    %s\n' "$line"
  else
    printf 'FAIL  %s: want /%s/, got: %s\n' "$1" "$2" "${line:-nothing}"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_counts() {
  if [[ ${#ZONE_PROBLEMS[@]} -eq "$1" && "$ZONE_WARNED" -eq "$2" ]]; then
    printf 'ok    %d failed, %d warned\n' "$1" "$2"
  else
    printf 'FAIL  want %d failed %d warned, got %d failed %d warned\n' \
      "$1" "$2" "${#ZONE_PROBLEMS[@]}" "$ZONE_WARNED"
    FAILURES=$((FAILURES + 1))
  fi
}

printf '== all UTC\n'
reset_zone_state
HOST_ZONE='Etc/UTC'
CLI_ZONE='UTC'
FPM_ZONE='UTC'
DB_REPLY=(
  ["rsvp:${RSVP_DB}"]='+00:00 +00:00 UTC'
  ["wp:${AMPAS_ROOT}/.env"]='SYSTEM SYSTEM UTC'
  ["wp:${GUILDS_ROOT}/.env"]='UTC UTC UTC'
)
run_zone_checks staging
expect 'host' '^  ok .* Etc/UTC$'
expect 'php cli' '^  ok .* UTC$'
expect 'php8\.4 fpm' '^  ok .* UTC$'
expect 'rsvp db' '^  ok .* global \+00:00, session \+00:00$'
expect 'ampas db' '^  ok .* global UTC, session UTC$'
expect 'guilds db' '^  ok .* global UTC, session UTC$'
expect_counts 0 0

printf '== drifted\n'
reset_zone_state
HOST_ZONE='America/Los_Angeles'
FPM_ZONE='America/Los_Angeles'
DB_REPLY=(
  ["rsvp:${RSVP_DB}"]='SYSTEM SYSTEM PST'
  ["wp:${AMPAS_ROOT}/.env"]='error connect-2002'
  ["wp:${GUILDS_ROOT}/.env"]='+00:00 -08:00 UTC'
)
run_zone_checks staging
expect 'host' '^  FAIL .* America/Los_Angeles, want UTC$'
expect 'php cli' '^  ok .* UTC$'
expect 'php8\.4 fpm' '^  FAIL .* America/Los_Angeles, want UTC$'
expect 'rsvp db' '^  FAIL .* global PST, session PST, want UTC'
expect 'ampas db' '^  WARN .* not read \(connect-2002\)'
expect 'guilds db' '^  FAIL .* session -08:00, want UTC'
expect_counts 4 1

printf '== %d failure(s)\n' "$FAILURES"
exit "$FAILURES"
