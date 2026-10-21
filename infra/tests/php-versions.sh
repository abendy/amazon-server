#!/usr/bin/env bash
# Version-switch test for infra/php-sites.sh. Sources the library with a
# temporary PHP_SYSROOT and stubbed apt-get, systemctl, update-alternatives and
# install, then converges four site layouts in turn:
#   1. all three sites at 7.4: today's pools, pin, packages and units
#   2. RSVP at 8.4: its pool and nginx socket move, 7.4 keeps two pools
#   4. RSVP back at 7.4: the 8.4 pools and sockets go away
#   3. all three at 8.4: the 7.4 FPM is stopped and disabled
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$TESTS_DIR")"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export PHP_SYSROOT="${WORK_DIR}/root"
CALLS="${WORK_DIR}/calls"
PHP_FPM_LOG_ROOT='/var/log/php-fpm'
PHP_CLI_VERSION='7.4'
RSVP_PHP_VERSION=''
AMPAS_PHP_VERSION=''
GUILDS_PHP_VERSION=''
OWNED_FILES=()
FAILURES=0
CASE=''

# shellcheck source=infra/php-sites.sh
source "${INFRA_DIR}/php-sites.sh"

own_file() {
  OWNED_FILES+=("$@")
}

# Ownership needs root; the test checks placement and content only.
install() {
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o | -g) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  command install "${args[@]}"
}

# A php<ver>-fpm install lays down what the package would: the conf.d and
# pool.d directories, the FPM binary and, on a first install only, www.conf.
apt-get() {
  printf 'apt-get %s\n' "$*" >> "$CALLS"
  local package version etc
  for package in "$@"; do
    [[ "$package" =~ ^php([0-9]+\.[0-9]+)-fpm$ ]] || continue
    version="${BASH_REMATCH[1]}"
    etc="${PHP_SYSROOT}/etc/php/${version}"
    if [[ ! -d "${etc}/fpm/pool.d" ]]; then
      mkdir -p "${etc}/fpm/pool.d" "${etc}/fpm/conf.d" "${etc}/cli/conf.d" "${PHP_SYSROOT}/usr/sbin"
      printf '[www]\n' > "${etc}/fpm/pool.d/www.conf"
      printf '#!/bin/sh\n' > "${PHP_SYSROOT}/usr/sbin/php-fpm${version}"
      chmod 0755 "${PHP_SYSROOT}/usr/sbin/php-fpm${version}"
    fi
  done
}

update-alternatives() {
  printf 'update-alternatives %s\n' "$*" >> "$CALLS"
}

# A restart serves exactly the sockets of the version's pools; a stop serves none.
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$CALLS"
  local version="${2#php}" pool listen
  version="${version%-fpm}"
  mkdir -p "${PHP_SYSROOT}/run/php"
  case "$1" in
    restart | stop)
      rm -f "${PHP_SYSROOT}/run/php/php${version}-fpm-"*.sock
      ;;
  esac
  if [[ "$1" == restart ]]; then
    for pool in "${PHP_SYSROOT}/etc/php/${version}/fpm/pool.d/"*.conf; do
      [[ -e "$pool" ]] || continue
      listen="$(awk -F' = ' '$1 == "listen" { print $2 }' "$pool")"
      if [[ -n "$listen" ]]; then
        : > "${PHP_SYSROOT}${listen}"
      fi
    done
  fi
}

# The PHP steps in cloud-init.sh's order. nginx renders between the two pool
# steps; the stand-in records the socket each site's server block gets.
converge() {
  RSVP_PHP_VERSION="$1"
  AMPAS_PHP_VERSION="$2"
  GUILDS_PHP_VERSION="$3"
  OWNED_FILES=()
  : > "$CALLS"
  php_write_apt_pins
  apt-get update
  php_install_packages
  php_write_timezone_ini
  php_write_security_ini
  php_enable_units
  php_place_pools
  local site
  for site in "${PHP_SITES[@]}"; do
    printf 'nginx %s unix:%s\n' "$site" "$(php_site_socket "$site")" >> "$CALLS"
  done
  php_retire_stale
}

fail() {
  printf 'FAIL case %s: %s\n' "$CASE" "$*"
  FAILURES=$((FAILURES + 1))
}

expect_text() {  # expect_text <what> <expected> <actual>
  if [[ "$2" != "$3" ]]; then
    fail "$1"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /' || true
  fi
}

expect_file() {  # expect_file <path under the root> <expected content>
  local file="${PHP_SYSROOT}$1"
  if [[ ! -f "$file" ]]; then
    fail "$1 missing"
  else
    expect_text "$1" "$2" "$(<"$file")"
  fi
}

expect_absent() {
  if [[ -e "${PHP_SYSROOT}$1" ]]; then
    fail "$1 should not exist"
  fi
}

expect_present() {
  if [[ ! -e "${PHP_SYSROOT}$1" ]]; then
    fail "$1 should exist"
  fi
}

expect_pools() {  # expect_pools <version> <pool names, sorted, space-separated or empty>
  local dir="${PHP_SYSROOT}/etc/php/$1/fpm/pool.d" actual=''
  if [[ -d "$dir" ]]; then
    actual="$(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd ' ' -)"
  fi
  expect_text "PHP $1 pool.d holds [$2]" "$2" "$actual"
}

expect_sockets() {  # expect_sockets <sorted socket paths, space-separated or empty>
  local actual=''
  if [[ -d "${PHP_SYSROOT}/run/php" ]]; then
    actual="$(find "${PHP_SYSROOT}/run/php" -mindepth 1 -printf '/run/php/%f\n' | sort | paste -sd ' ' -)"
  fi
  expect_text "served sockets" "$1" "$actual"
}

expect_calls() {
  expect_text "apt, alternatives, systemd and nginx calls" "$1" "$(<"$CALLS")"
}

pool_text() {  # pool_text <site> <version>: the pool file cloud-init wrote before RS-13
  cat <<POOL
[$1]
user = www-data
group = www-data
listen = /run/php/php$2-fpm-$1.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 20
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 5
pm.max_requests = 500
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php-fpm/$1-error.log
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[max_execution_time] = 600
php_admin_value[max_input_time] = 600
POOL
}

pin_text() {
  printf 'Package: php%s*\nPin: version %s.*\nPin-Priority: 1001' "$1" "$1"
}

packages_line() {
  local version
  local -a packages=()
  for version in "$@"; do
    packages+=("php${version}-cli" "php${version}-curl" "php${version}-fpm" "php${version}-gd"
      "php${version}-intl" "php${version}-mbstring" "php${version}-mysql" "php${version}-xml"
      "php${version}-zip")
  done
  printf '%s' "${packages[*]}"
}

nginx_lines() {  # nginx_lines <rsvp> <ampas> <guilds>
  printf 'nginx rsvp unix:/run/php/php%s-fpm-rsvp.sock\n' "$1"
  printf 'nginx ampas unix:/run/php/php%s-fpm-ampas.sock\n' "$2"
  printf 'nginx guilds unix:/run/php/php%s-fpm-guilds.sock' "$3"
}

tree_digest() {
  (cd "$PHP_SYSROOT" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}

# ---- cloud-init.sh runs the same steps -------------------------------------

CASE='wiring'
expect_text 'cloud-init.sh PHP steps, in order' \
  "$(printf '%s\n' php_write_apt_pins php_install_packages php_write_timezone_ini \
    php_write_security_ini php_enable_units php_place_pools php_retire_stale)" \
  "$(grep -oE '^php_[a-z_]+$' "${INFRA_DIR}/cloud-init.sh")"
for site in RSVP AMPAS GUILDS; do
  lower="${site,,}"
  if ! grep -qxF "STAGING_${site}_FPM_SOCKET=\"\$(php_site_socket ${lower})\"" "${INFRA_DIR}/cloud-init.sh"; then
    fail "cloud-init.sh does not derive STAGING_${site}_FPM_SOCKET from php_site_socket"
  fi
done

# ---- 1. all three sites at 7.4 ----------------------------------------------

CASE='1 (all at 7.4)'
converge 7.4 7.4 7.4
# Today's calls, plus the CLI pin.
expect_calls "apt-get update
apt-get install -y $(packages_line 7.4)
update-alternatives --set php /usr/bin/php7.4
systemctl enable php7.4-fpm
systemctl restart php7.4-fpm
$(nginx_lines 7.4 7.4 7.4)"
expect_pools 7.4 'ampas.conf guilds.conf rsvp.conf'
for site in rsvp ampas guilds; do
  expect_file "/etc/php/7.4/fpm/pool.d/${site}.conf" "$(pool_text "$site" 7.4)"
done
expect_file /etc/apt/preferences.d/amazon-php74 "$(pin_text 7.4)"
expect_file /etc/php/7.4/fpm/conf.d/zz-amazon-timezone.ini 'date.timezone = UTC'
expect_file /etc/php/7.4/cli/conf.d/zz-amazon-timezone.ini 'date.timezone = UTC'
expect_file /etc/php/7.4/fpm/conf.d/zz-amazon-security.ini '; CVE-2026-109619: no site uses upload progress. Keep off after patching.
session.upload_progress.enabled = 0'
expect_sockets '/run/php/php7.4-fpm-ampas.sock /run/php/php7.4-fpm-guilds.sock /run/php/php7.4-fpm-rsvp.sock'
expect_text 'owned files' "$(printf '%s\n' \
  "${PHP_SYSROOT}/etc/apt/preferences.d/amazon-php74" \
  "${PHP_SYSROOT}/etc/php/7.4/fpm/conf.d/zz-amazon-timezone.ini" \
  "${PHP_SYSROOT}/etc/php/7.4/cli/conf.d/zz-amazon-timezone.ini" \
  "${PHP_SYSROOT}/etc/php/7.4/fpm/conf.d/zz-amazon-security.ini" \
  "${PHP_SYSROOT}/etc/php/7.4/fpm/pool.d/rsvp.conf" \
  "${PHP_SYSROOT}/etc/php/7.4/fpm/pool.d/ampas.conf" \
  "${PHP_SYSROOT}/etc/php/7.4/fpm/pool.d/guilds.conf" \
  "${PHP_SYSROOT}/etc/amazon-server.php-sites")" "$(printf '%s\n' "${OWNED_FILES[@]}")"
expect_file /etc/amazon-server.php-sites "rsvp_version=7.4
rsvp_pool=/etc/php/7.4/fpm/pool.d/rsvp.conf
rsvp_socket=/run/php/php7.4-fpm-rsvp.sock
rsvp_php=/usr/bin/php7.4
ampas_version=7.4
ampas_pool=/etc/php/7.4/fpm/pool.d/ampas.conf
ampas_socket=/run/php/php7.4-fpm-ampas.sock
ampas_php=/usr/bin/php7.4
guilds_version=7.4
guilds_pool=/etc/php/7.4/fpm/pool.d/guilds.conf
guilds_socket=/run/php/php7.4-fpm-guilds.sock
guilds_php=/usr/bin/php7.4
cli_version=7.4
cli_php=/usr/bin/php7.4
packages=$(packages_line 7.4)"

CASE='1 (all at 7.4, re-run)'
first_digest="$(tree_digest)"
first_calls="$(<"$CALLS")"
converge 7.4 7.4 7.4
expect_text 'a second converge writes the same files' "$first_digest" "$(tree_digest)"
expect_calls "$first_calls"

# ---- 2. RSVP at 8.4 ---------------------------------------------------------

CASE='2 (RSVP at 8.4)'
converge 8.4 7.4 7.4
expect_calls "apt-get update
apt-get install -y $(packages_line 7.4 8.4)
update-alternatives --set php /usr/bin/php7.4
systemctl enable php7.4-fpm
systemctl enable php8.4-fpm
systemctl restart php7.4-fpm
systemctl restart php8.4-fpm
$(nginx_lines 8.4 7.4 7.4)
systemctl restart php7.4-fpm"
expect_pools 8.4 'rsvp.conf'
expect_pools 7.4 'ampas.conf guilds.conf'
expect_file /etc/php/8.4/fpm/pool.d/rsvp.conf "$(pool_text rsvp 8.4)"
expect_file /etc/php/7.4/fpm/pool.d/ampas.conf "$(pool_text ampas 7.4)"
expect_file /etc/apt/preferences.d/amazon-php74 "$(pin_text 7.4)"
expect_file /etc/apt/preferences.d/amazon-php84 "$(pin_text 8.4)"
expect_file /etc/php/8.4/fpm/conf.d/zz-amazon-timezone.ini 'date.timezone = UTC'
expect_file /etc/php/8.4/cli/conf.d/zz-amazon-timezone.ini 'date.timezone = UTC'
expect_file /etc/php/8.4/fpm/conf.d/zz-amazon-security.ini '; CVE-2026-109619: no site uses upload progress. Keep off after patching.
session.upload_progress.enabled = 0'
expect_sockets '/run/php/php7.4-fpm-ampas.sock /run/php/php7.4-fpm-guilds.sock /run/php/php8.4-fpm-rsvp.sock'
if ! grep -qxF 'rsvp_php=/usr/bin/php8.4' "$PHP_SETTINGS_FILE"; then
  fail 'settings do not give RSVP /usr/bin/php8.4'
fi

# ---- 4. RSVP moved back to 7.4 ----------------------------------------------

CASE='4 (RSVP back at 7.4)'
converge 7.4 7.4 7.4
expect_calls "apt-get update
apt-get install -y $(packages_line 7.4)
update-alternatives --set php /usr/bin/php7.4
systemctl enable php7.4-fpm
systemctl restart php7.4-fpm
$(nginx_lines 7.4 7.4 7.4)
systemctl stop php8.4-fpm
systemctl disable php8.4-fpm"
expect_pools 8.4 ''
expect_pools 7.4 'ampas.conf guilds.conf rsvp.conf'
expect_file /etc/php/7.4/fpm/pool.d/rsvp.conf "$(pool_text rsvp 7.4)"
expect_absent /etc/apt/preferences.d/amazon-php84
expect_present /usr/sbin/php-fpm8.4
expect_sockets '/run/php/php7.4-fpm-ampas.sock /run/php/php7.4-fpm-guilds.sock /run/php/php7.4-fpm-rsvp.sock'

# ---- 3. all three sites at 8.4 ----------------------------------------------

CASE='3 (all at 8.4)'
converge 8.4 8.4 8.4
expect_calls "apt-get update
apt-get install -y $(packages_line 7.4 8.4)
update-alternatives --set php /usr/bin/php7.4
systemctl enable php8.4-fpm
systemctl restart php8.4-fpm
$(nginx_lines 8.4 8.4 8.4)
systemctl stop php7.4-fpm
systemctl disable php7.4-fpm"
expect_pools 7.4 ''
expect_pools 8.4 'ampas.conf guilds.conf rsvp.conf'
for site in rsvp ampas guilds; do
  expect_file "/etc/php/8.4/fpm/pool.d/${site}.conf" "$(pool_text "$site" 8.4)"
done
expect_sockets '/run/php/php8.4-fpm-ampas.sock /run/php/php8.4-fpm-guilds.sock /run/php/php8.4-fpm-rsvp.sock'
expect_file /etc/apt/preferences.d/amazon-php74 "$(pin_text 7.4)"

if [[ "$FAILURES" -eq 0 ]]; then
  printf 'PASS php-versions: cases 1, 2, 4 and 3\n'
fi
exit "$FAILURES"
