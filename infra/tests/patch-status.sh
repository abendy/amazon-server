#!/usr/bin/env bash
# OS patch checks in infra/converge.sh status. Sources the script for its
# functions, stubs apt-get, apt-config, systemctl, dpkg-query and uname, and
# runs the checks against two hosts:
#   1. healthy: daily job on, one PHP and two other upgrades waiting, few kernels
#   2. neglected: timer off, a security upgrade waiting, reboot pending, stale
#      lists, too many kernels
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$TESTS_DIR")"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILURES=0

# shellcheck source=infra/converge.sh
source "${INFRA_DIR}/converge.sh"

TIMER_STATE='active'
PERIODIC='1'
SIMULATION=''
KERNELS=''

# The stubs below shadow the real commands that converge.sh calls.
# shellcheck disable=SC2329
systemctl() {
  case "$1" in
    is-active) printf '%s\n' "$TIMER_STATE" ;;
    is-enabled) printf 'enabled\n' ;;
  esac
}
# Literal apt-config output: the ${...} are apt's own variables.
# shellcheck disable=SC2016
apt-config() {
  printf 'APT::Periodic::Unattended-Upgrade "%s";\n' "$PERIODIC"
  printf 'Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}";\n'
  printf 'Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-security";\n'
}
apt-get() { printf '%s' "$SIMULATION"; }
dpkg-query() { printf '%s' "$KERNELS"; }
uname() { printf '7.0.0-1017-aws\n'; }

REBOOT_REQUIRED_FILE="${WORK_DIR}/reboot-required"
APT_UPDATE_STAMP="${WORK_DIR}/update-success-stamp"

reset_patch_state() {
  PATCH_LINES=()
  PATCH_PROBLEMS=()
  PATCH_WARNED=0
}

# expect <label> <pattern>: one PATCH_LINES entry for the label matches the pattern.
expect() {
  local line
  line="$(printf '%s\n' "${PATCH_LINES[@]}" | grep -E "^  [a-zA-Z]+ +${1} " || true)"
  if [[ "$line" =~ $2 ]]; then
    printf 'ok    %s\n' "$line"
  else
    printf 'FAIL  %s: want /%s/, got: %s\n' "$1" "$2" "${line:-nothing}"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_counts() {
  if [[ ${#PATCH_PROBLEMS[@]} -eq "$1" && "$PATCH_WARNED" -eq "$2" ]]; then
    printf 'ok    %d failed, %d warned\n' "$1" "$2"
  else
    printf 'FAIL  want %d failed %d warned, got %d failed %d warned\n' \
      "$1" "$2" "${#PATCH_PROBLEMS[@]}" "$PATCH_WARNED"
    FAILURES=$((FAILURES + 1))
  fi
}

printf '== healthy host\n'
reset_patch_state
touch "$APT_UPDATE_STAMP"
SIMULATION='Reading package lists...
Inst perl [5.38.2-3.2ubuntu0.1] (5.38.2-3.2ubuntu0.2 Ubuntu:24.04/noble-updates [amd64])
Inst console-setup-linux [1.226ubuntu1] (1.226ubuntu1.1 Ubuntu:24.04/noble-updates [all])
Inst php8.4-fpm [8.4.27-1+0~20261021.57+ubuntu24.04~1.gbp7636b9] (8.4.28-1+0~20261120.58+ubuntu24.04~1.gbp1a2b3c noble [amd64])
Conf perl (5.38.2-3.2ubuntu0.2 Ubuntu:24.04/noble-updates [amd64])
'
KERNELS='ii linux-image-7.0.0-1014-aws
ii linux-image-7.0.0-1017-aws
rc linux-image-6.8.0-1009-aws
'
run_patch_checks
expect 'auto updates' '^  ok .* daily; 1 security origins allowed$'
expect 'package lists' '^  ok .* refreshed 0h ago$'
expect 'security' '^  ok .* none waiting$'
expect 'updates' '^  info .* 2 waiting for the patch window$'
expect 'php' '^  info .* 1 waiting for the patch window: php8\.4-fpm$'
expect 'reboot' '^  ok .* not required$'
expect 'kernels' '^  ok .* running 7\.0\.0-1017-aws; 2 images installed$'
expect_counts 0 0

printf '== neglected host\n'
reset_patch_state
TIMER_STATE='inactive'
touch -d '3 days ago' "$APT_UPDATE_STAMP"
printf '*** System restart required ***\n' > "$REBOOT_REQUIRED_FILE"
printf 'linux-image-7.0.0-1017-aws\nlibc6\nlibc6\n' > "${REBOOT_REQUIRED_FILE}.pkgs"
SIMULATION='Inst openssl [3.0.13-0ubuntu3.6] (3.0.13-0ubuntu3.7 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64])
'
KERNELS='ii linux-image-6.17.0-1019-aws
ii linux-image-7.0.0-1012-aws
ii linux-image-7.0.0-1014-aws
ii linux-image-7.0.0-1017-aws
'
run_patch_checks
expect 'auto updates' '^  FAIL .* apt-daily-upgrade\.timer inactive enabled'
expect 'package lists' '^  WARN .* last refreshed (71|72)h ago'
expect 'security' '^  WARN .* 1 waiting'
expect 'updates' '^  info .* 0 waiting'
expect 'php' '^  ok .* none waiting$'
expect 'reboot' '^  WARN .* required by libc6 linux-image-7\.0\.0-1017-aws$'
expect 'kernels' '^  WARN .* 4 images installed, remove old ones'
expect_counts 1 4

printf '== %d failure(s)\n' "$FAILURES"
exit "$FAILURES"
