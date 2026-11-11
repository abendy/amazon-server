#!/usr/bin/env bash
# Cron-line check for the RSVP jobs in infra/cron/. Renders each file the way
# install_reminder_cron and install_confirmation_cron in infra/cloud-init.sh do
# (envsubst of RSVP_PHP_BIN only) and checks its one job line: schedule, user,
# PHP_BIN, wrapper path and syslog tag. The confirmation job runs every 15
# minutes and never in the minute the hourly reminder job starts. Also checks
# that cloud-init.sh installs both on production. Runs nothing it renders.
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$TESTS_DIR")"
FAILURES=0
PHP_BIN_RENDERED='/usr/bin/php8.4'
WRAPPERS='/var/www/html/rsvp/admin/application/scripts'

check() {
  local name=$1 actual=$2 expected=$3
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$name" "$expected" "$actual"
    FAILURES=$((FAILURES + 1))
  fi
}

# render <cron file>: its job lines, rendered as converge renders them.
render() {
  if [[ ! -f "$1" ]]; then
    return
  fi
  RSVP_PHP_BIN="$PHP_BIN_RENDERED" envsubst "\${RSVP_PHP_BIN}" < "$1" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' || true
}

# minutes <minute field>: every minute of the hour it matches, space-separated.
minutes() {
  local field=$1 m out=''
  if [[ ! "$field" =~ ^[0-9*/,-]+$ ]]; then
    printf 'not a minute field: %s' "$field"
    return
  fi
  for m in $(seq 0 59); do
    local part matched=0
    IFS=',' read -r -a parts <<< "$field"
    for part in "${parts[@]}"; do
      local range=$part step=1 lo hi
      if [[ "$part" == */* ]]; then range=${part%/*}; step=${part#*/}; fi
      if [[ "$range" == '*' ]]; then lo=0; hi=59
      elif [[ "$range" == *-* ]]; then lo=${range%-*}; hi=${range#*-}
      else lo=$range; hi=$range; fi
      if (( m >= lo && m <= hi && (m - lo) % step == 0 )); then matched=1; fi
    done
    if (( matched )); then out+="$m "; fi
  done
  printf '%s' "${out% }"
}

printf '== reminders (unchanged)\n'
reminder_line="$(render "${INFRA_DIR}/cron/amazon-rsvp-reminders")"
read -r -a r <<< "$reminder_line"
check 'reminders: one job line' "$(printf '%s\n' "$reminder_line" | grep -c . || true)" '1'
check 'reminders: hourly, at minute 0' "${r[0]:-} ${r[1]:-} ${r[2]:-} ${r[3]:-} ${r[4]:-}" '0 * * * *'
check 'reminders: as www-data' "${r[5]:-}" 'www-data'
check 'reminders: PHP_BIN rendered' "$(grep -o "PHP_BIN=[^ ]*" <<< "$reminder_line")" "PHP_BIN=${PHP_BIN_RENDERED}"
check 'reminders: the reminder wrapper, errors to syslog' \
  "$(grep -o "${WRAPPERS}/[^ ]* 2>&1 >/dev/null | logger -t [^ ]*" <<< "$reminder_line")" \
  "${WRAPPERS}/run_reminder.production.sh 2>&1 >/dev/null | logger -t amazon-rsvp-reminders"

printf '== confirmations\n'
confirmation_line="$(render "${INFRA_DIR}/cron/amazon-rsvp-confirmations")"
read -r -a c <<< "$confirmation_line"
check 'confirmations: the cron file exists' "$([[ -f "${INFRA_DIR}/cron/amazon-rsvp-confirmations" ]] && echo yes || echo no)" 'yes'
check 'confirmations: one job line' "$(printf '%s\n' "$confirmation_line" | grep -c . || true)" '1'
check 'confirmations: every hour, every day' "${c[1]:-} ${c[2]:-} ${c[3]:-} ${c[4]:-}" '* * * *'
check 'confirmations: four runs an hour, 15 minutes apart, never at minute 0' "$(minutes "${c[0]:-0}")" '5 20 35 50'
check 'confirmations: as www-data' "${c[5]:-}" 'www-data'
check 'confirmations: PHP_BIN rendered, no ping URL' "$(grep -o "[A-Z_]*=[^ ]*" <<< "$confirmation_line" | tr '\n' ' ')" "PHP_BIN=${PHP_BIN_RENDERED} "
check 'confirmations: the confirmation wrapper, errors to syslog' \
  "$(grep -o "${WRAPPERS}/[^ ]* 2>&1 >/dev/null | logger -t [^ ]*" <<< "$confirmation_line")" \
  "${WRAPPERS}/run_confirmations.production.sh 2>&1 >/dev/null | logger -t amazon-rsvp-confirmations"

printf '== cloud-init.sh\n'
cloud_init="${INFRA_DIR}/cloud-init.sh"
check 'cloud-init: installs the confirmation cron after the reminder cron' \
  "$(grep -E '^install_(reminder|confirmation)_cron$' "$cloud_init" | tr '\n' ' ')" \
  'install_reminder_cron install_confirmation_cron '
check 'cloud-init: from infra/cron to /etc/cron.d, for the confirmation wrapper' \
  "$(sed -n '/^install_confirmation_cron() {/,/^}/p' "$cloud_init" | grep -oE "amazon-rsvp-confirmations'?\"?|run_confirmations\.production\.sh" | tr -d "'\"" | tr '\n' ' ')" \
  'amazon-rsvp-confirmations amazon-rsvp-confirmations run_confirmations.production.sh '
check 'cloud-init: production only' \
  "$(sed -n '/^install_confirmation_cron() {/,/^}/p' "$cloud_init" | grep -c "AMAZON_SERVER_ENVIRONMENT\" != 'production'")" '1'

exit "$FAILURES"
