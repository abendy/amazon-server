#!/usr/bin/env bash
# Staging local-database checks in infra/converge.sh status. Sources the script
# for its functions, points it at copies of the repo's two MySQL config files,
# stubs systemctl, ss, mysql and swapon, and runs the checks four times:
#   1. current: running, local-only, every value as configured, swap active
#   2. drifted: listening on every address, two values off, no swap
#   3. down: mysql stopped, so nothing is read
#   4. production: skipped, it keeps its managed databases
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$TESTS_DIR")"
REPO_DIR="$(dirname "$INFRA_DIR")"
FAILURES=0

# shellcheck source=infra/converge.sh
source "${INFRA_DIR}/converge.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cp "${REPO_DIR}/mysql/server-parity.cnf" "${WORK_DIR}/parity.cnf"
cp "${REPO_DIR}/mysql/staging-local.cnf" "${WORK_DIR}/staging.cnf"
MYSQL_PARITY_CONF="${WORK_DIR}/parity.cnf"
MYSQL_LOCAL_CONF="${WORK_DIR}/staging.cnf"

SERVICE_ACTIVE=true
LISTENERS=()
SWAP_LINE=''
declare -A VARS=()

# The stubs below shadow the real commands that converge.sh calls.
# shellcheck disable=SC2329
systemctl() { [[ "$SERVICE_ACTIVE" == true ]]; }
# shellcheck disable=SC2329
ss() {
  local address
  for address in "${LISTENERS[@]}"; do
    printf 'LISTEN 0 151 %s 0.0.0.0:*\n' "$address"
  done
  printf 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:*\n'
}
# shellcheck disable=SC2329
mysql() {
  local query="${*: -1}" name
  [[ "$SERVICE_ACTIVE" == true ]] || return 1
  name="${query#SELECT @@global.}"
  [[ -v "VARS[$name]" ]] || return 1
  printf '%s\n' "${VARS[$name]}"
}
# shellcheck disable=SC2329
swapon() { [[ -z "$SWAP_LINE" ]] || printf '%s\n' "$SWAP_LINE"; }

current_vars() {
  VARS=(
    [sql_mode]='NO_ENGINE_SUBSTITUTION'
    [character_set_server]='utf8mb4'
    [collation_server]='utf8mb4_0900_ai_ci'
    [time_zone]='+00:00'
    [default_authentication_plugin]='mysql_native_password'
    [max_allowed_packet]='67108864'
    [local_infile]='1'
    [bind_address]='127.0.0.1'
    [mysqlx_bind_address]='127.0.0.1'
    [innodb_buffer_pool_size]='268435456'
  )
}

reset_db_state() {
  DB_LINES=()
  DB_PROBLEMS=()
}

# expect <label> <pattern>: the DB_LINES entry for the label matches the pattern.
expect() {
  local line
  line="$(printf '%s\n' "${DB_LINES[@]}" | grep -E "^  [a-zA-Z]+ +${1} " || true)"
  if [[ "$line" =~ $2 ]]; then
    printf 'ok    %s\n' "$line"
  else
    printf 'FAIL  %s: want /%s/, got: %s\n' "$1" "$2" "${line:-nothing}"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_failed() {
  if [[ ${#DB_PROBLEMS[@]} -eq "$1" ]]; then
    printf 'ok    %d failed\n' "$1"
  else
    printf 'FAIL  want %d failed, got %d: %s\n' "$1" "${#DB_PROBLEMS[@]}" "${DB_PROBLEMS[*]}"
    FAILURES=$((FAILURES + 1))
  fi
}

printf '== current\n'
reset_db_state
SERVICE_ACTIVE=true
LISTENERS=('127.0.0.1:3306' '127.0.0.1:33060')
SWAP_LINE='/swapfile 1073737728'
current_vars
run_db_checks staging
expect 'service' '^  ok .* mysql active$'
expect 'listen' '^  ok .* 127\.0\.0\.1:3306 127\.0\.0\.1:33060$'
expect 'settings' '^  ok .* 10 values match'
expect 'swap' '^  ok .* /swapfile active, 1073737728 bytes$'
expect_failed 0

printf '== drifted\n'
reset_db_state
LISTENERS=('0.0.0.0:3306' '127.0.0.1:33060')
SWAP_LINE=''
current_vars
VARS[sql_mode]='ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES'
VARS[innodb_buffer_pool_size]='134217728'
run_db_checks staging
expect 'service' '^  ok '
expect 'listen' '^  FAIL .* 0\.0\.0\.0:3306 reachable beyond this host'
expect 'settings' '^  FAIL .* sql_mode is only_full_group_by,strict_trans_tables, want no_engine_substitution; innodb_buffer_pool_size is 134217728, want 268435456$'
expect 'swap' '^  FAIL .* /swapfile not active$'
expect_failed 3

printf '== down\n'
reset_db_state
SERVICE_ACTIVE=false
LISTENERS=()
SWAP_LINE='/swapfile 1073737728'
run_db_checks staging
expect 'service' '^  FAIL .* mysql not running$'
expect 'listen' '^  FAIL .* nothing listens on 3306 or 33060$'
expect 'settings' '^  FAIL .* not read: mysql is down or refused root$'
expect 'swap' '^  ok '
expect_failed 3

printf '== production\n'
reset_db_state
run_db_checks production
expect 'local db' '^  skip .* production uses its managed databases$'
expect_failed 0

printf '== %d failure(s)\n' "$FAILURES"
exit "$FAILURES"
