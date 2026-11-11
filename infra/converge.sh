#!/usr/bin/env bash
# amazon-server-converge: apply this repo at the instance's ref, or report drift.
#
# infra/cloud-init.sh installs this file as /usr/local/sbin/amazon-server-converge
# on every run; /usr/local/sbin/amazon-staging-provision is a symlink to it.
# See infra/README.md, "Converge and status".
#
#   sudo amazon-server-converge                   fetch the ref, run the repo's provisioner
#   sudo amazon-server-converge status [--short]  read-only verdict, exit 0 only on CURRENT
set -Eeuo pipefail

AMAZON_SERVER_ROOT='/opt/amazon-server'
PROVISIONER="${AMAZON_SERVER_ROOT}/infra/cloud-init.sh"
REF_FILE='/etc/amazon-server.ref'
ENVIRONMENT_FILE='/etc/amazon-server.env'
APPLIED_FILE='/etc/amazon-server.applied'
MANIFEST_FILE='/var/lib/amazon-server/applied.sha256'
# The PHP settings converge applied (infra/php-sites.sh, php_write_settings).
PHP_SETTINGS_FILE='/etc/amazon-server.php-sites'
PHP_SITES=(rsvp ampas guilds)
# The CLI alternatives converge keeps on the CLI version (infra/php-sites.sh).
PHP_CLI_ALTERNATIVES=(php phar phar.phar)

# Manual state that status checks by presence, owner, mode and key names only.
DB_ENV_FILE='/root/amazon-staging/db.env'
AUTH_FILE='/etc/nginx/.htpasswd'
AMPAS_ROOT='/var/www/html/amazon-studios-ampas'
GUILDS_ROOT='/var/www/html/amazon-studios-guilds'
RSVP_ROOT='/var/www/html/rsvp'
WP_ENV_KEYS=(
  DB_NAME DB_USER DB_PASSWORD DB_HOST
  WP_ENV WP_HOME WP_SITEURL
  AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY
  AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT
)

die() {
  printf 'amazon-server-converge: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: amazon-server-converge [status [--short]]\n' >&2
  exit "${1:-2}"
}

# read_setting <file> <default>: the file's single word, or the default.
read_setting() {
  local value=''
  if [[ -r "$1" ]]; then
    value="$(<"$1")"
    value="${value//[[:space:]]/}"
  fi
  printf '%s' "${value:-$2}"
}

checkout_is_dirty() {
  [[ -n "$(git --no-optional-locks -C "$AMAZON_SERVER_ROOT" status --porcelain)" ]]
}

converge_apply() {
  local ref environment sha
  ref="$(read_setting "$REF_FILE" develop)"
  environment="$(read_setting "$ENVIRONMENT_FILE" staging)"

  if [[ "$environment" == 'production' && "$ref" != 'master' ]]; then
    die "refusing to converge production from '${ref}'; production converges only from master (${REF_FILE})"
  fi
  if [[ ! -d "${AMAZON_SERVER_ROOT}/.git" ]]; then
    die "${AMAZON_SERVER_ROOT} is not a Git checkout; use the first-converge recipe in infra/README.md"
  fi
  if checkout_is_dirty; then
    die "${AMAZON_SERVER_ROOT} has uncommitted changes; land them in _server or discard them first"
  fi

  git -C "$AMAZON_SERVER_ROOT" fetch --depth 1 origin "$ref"
  git -C "$AMAZON_SERVER_ROOT" checkout --detach FETCH_HEAD
  sha="$(git -C "$AMAZON_SERVER_ROOT" rev-parse HEAD)"
  printf 'amazon-server-converge: %s from %s at %s\n' "$environment" "$ref" "$sha"

  # cloud-init.sh skips its own fetch when this is set, so the script bash is
  # about to read is never rewritten while it runs.
  export AMAZON_SERVER_CONVERGE_SHA="$sha"
  exec bash "$PROVISIONER"
}

# ---- status ---------------------------------------------------------------

MANUAL_LINES=()
MANUAL_FAILED=0
MANUAL_WARNED=0

# manual_result <ok|WARN|FAIL|skip> <label> <detail>
manual_result() {
  MANUAL_LINES+=("$(printf '  %-4s  %-16s %s' "$1" "$2" "$3")")
  case "$1" in
    FAIL) MANUAL_FAILED=$((MANUAL_FAILED + 1)) ;;
    WARN) MANUAL_WARNED=$((MANUAL_WARNED + 1)) ;;
  esac
}

# file_facts <path>: owner:group, octal mode and size in bytes. Never content.
file_facts() {
  stat -c '%U:%G %a %sB' "$1"
}

# missing_key_names <file> <name>...: the names with no NAME= line in the file.
# grep -q prints nothing, so no value leaves the file.
missing_key_names() {
  local file="$1" name missing=''
  shift
  for name in "$@"; do
    if ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${name}=" "$file"; then
      missing+="${missing:+ }${name}"
    fi
  done
  printf '%s' "$missing"
}

# check_key_file <label> <path> <owner-or-empty> <group-or-empty> <mode> <name>...
check_key_file() {
  local label="$1" file="$2" want_owner="$3" want_group="$4" want_mode="$5"
  local owner group mode missing problems=''
  shift 5
  if [[ ! -f "$file" ]]; then
    manual_result FAIL "$label" "${file} missing"
    return
  fi
  owner="$(stat -c '%U' "$file")"
  group="$(stat -c '%G' "$file")"
  mode="$(stat -c '%a' "$file")"
  if [[ -n "$want_owner" && "$owner" != "$want_owner" ]]; then
    problems+="; owner should be ${want_owner}"
  fi
  if [[ -n "$want_group" && "$group" != "$want_group" ]]; then
    problems+="; group should be ${want_group}"
  fi
  if [[ "$mode" != "$want_mode" ]]; then
    problems+="; mode should be ${want_mode}"
  fi
  missing="$(missing_key_names "$file" "$@")"
  if [[ -n "$missing" ]]; then
    problems+="; missing key names: ${missing}"
  fi
  if [[ -n "$problems" ]]; then
    manual_result FAIL "$label" "${file} $(file_facts "$file")${problems}"
  else
    manual_result ok "$label" "${file} $(file_facts "$file"), $# key names"
  fi
}

check_present() {
  local label="$1" file="$2"
  if [[ -f "$file" ]]; then
    manual_result ok "$label" "${file} $(file_facts "$file")"
  else
    manual_result FAIL "$label" "${file} missing"
  fi
}

check_auth_file() {
  local environment="$1"
  if [[ "$environment" == 'production' ]]; then
    manual_result skip 'htpasswd' 'not checked: production has no embed gate'
  elif [[ ! -f "$AUTH_FILE" ]]; then
    manual_result FAIL 'htpasswd' "${AUTH_FILE} missing"
  elif [[ ! -s "$AUTH_FILE" ]]; then
    manual_result WARN 'htpasswd' "${AUTH_FILE} $(file_facts "$AUTH_FILE"), empty: only the exempt embed origins pass"
  elif ! runuser -u www-data -- test -r "$AUTH_FILE"; then
    manual_result FAIL 'htpasswd' "${AUTH_FILE} $(file_facts "$AUTH_FILE"), nginx cannot read it: logins return 500"
  else
    manual_result ok 'htpasswd' "${AUTH_FILE} $(file_facts "$AUTH_FILE")"
  fi
}

# origin_ssh_host <repo>: the SSH host (an ~/.ssh/config alias) in the
# checkout's origin URL, or nothing when the origin is not an SSH remote.
origin_ssh_host() {
  local url host=''
  url="$(git config --file "$1/.git/config" --get remote.origin.url 2>/dev/null || true)"
  case "$url" in
    ssh://*)
      host="${url#ssh://}"
      host="${host#*@}"
      host="${host%%[:/]*}"
      ;;
    *://*) ;;
    *:*)
      host="${url%%:*}"
      host="${host#*@}"
      ;;
  esac
  printf '%s' "$host"
}

check_ssh_aliases() {
  local ssh_home ssh_config site repo alias_name
  local -a hosts=()
  ssh_home="$(getent passwd ubuntu | cut -d: -f6 || true)"
  ssh_config="${ssh_home:-/home/ubuntu}/.ssh/config"
  if [[ -f "$ssh_config" ]]; then
    mapfile -t hosts < <(awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) print $i }' "$ssh_config")
  fi
  for site in ampas guilds rsvp; do
    case "$site" in
      ampas) repo="$AMPAS_ROOT" ;;
      guilds) repo="$GUILDS_ROOT" ;;
      rsvp) repo="$RSVP_ROOT" ;;
    esac
    if [[ ! -d "${repo}/.git" ]]; then
      manual_result FAIL "${site} ssh alias" "no checkout at ${repo}"
      continue
    fi
    alias_name="$(origin_ssh_host "$repo")"
    if [[ -z "$alias_name" ]]; then
      manual_result FAIL "${site} ssh alias" "${repo} origin is not an SSH alias remote"
    elif [[ ! -f "$ssh_config" ]]; then
      manual_result FAIL "${site} ssh alias" "${alias_name}: ${ssh_config} missing"
    elif printf '%s\n' "${hosts[@]}" | grep -qxF -- "$alias_name"; then
      manual_result ok "${site} ssh alias" "${alias_name} in ${ssh_config} $(file_facts "$ssh_config")"
    else
      manual_result FAIL "${site} ssh alias" "${alias_name} has no Host entry in ${ssh_config}"
    fi
  done
}

# Checkout folders belong to ubuntu, so deploys run as ubuntu; only the paths
# the apps write belong to www-data. A root-owned file is left over from a
# deploy run as root. Missing paths are skipped: the sites may not be cloned.
check_checkout_owners() {
  local path owner root_file problems=0
  local -a ubuntu_paths=(
    "$RSVP_ROOT" "${RSVP_ROOT}/public" "${RSVP_ROOT}/public/consideramazon"
    "$AMPAS_ROOT" "${AMPAS_ROOT}/web" "$GUILDS_ROOT" "${GUILDS_ROOT}/web"
  )
  local -a www_paths=(
    "${RSVP_ROOT}/admin/application/logs" "${AMPAS_ROOT}/web/app/uploads" "${GUILDS_ROOT}/web/app/uploads"
  )
  for path in "${ubuntu_paths[@]}"; do
    [[ -e "$path" ]] || continue
    owner="$(stat -c '%U' "$path")"
    if [[ "$owner" != ubuntu ]]; then
      manual_result FAIL 'checkout owner' "${path} is ${owner}, want ubuntu: converge resets it"
      problems=$((problems + 1))
    fi
  done
  for path in "${www_paths[@]}"; do
    [[ -e "$path" ]] || continue
    owner="$(stat -c '%U' "$path")"
    if [[ "$owner" != www-data ]]; then
      manual_result FAIL 'writable owner' "${path} is ${owner}, want www-data"
      problems=$((problems + 1))
    fi
  done
  for path in "$RSVP_ROOT" "$AMPAS_ROOT" "$GUILDS_ROOT"; do
    [[ -d "$path" ]] || continue
    root_file="$(find "$path" -user root -print -quit 2>/dev/null || true)"
    if [[ -n "$root_file" ]]; then
      manual_result FAIL 'root-owned' "${root_file} (and maybe more): chown the checkout back to ubuntu"
      problems=$((problems + 1))
    fi
  done
  if [[ "$problems" -eq 0 ]]; then
    manual_result ok 'checkout owner' 'checkouts ubuntu, writable paths www-data, no root-owned files'
  fi
}

run_manual_checks() {
  local environment="$1" site field
  local -a db_keys=()
  for site in RSVP AMPAS GUILDS; do
    for field in HOST PORT NAME USER PASSWORD; do
      db_keys+=("${site}_DB_${field}")
    done
  done
  # db.env is a setup handoff: nothing reads it at runtime, so its absence only warns.
  # A present file must still be root-only and complete.
  if [[ -f "$DB_ENV_FILE" ]]; then
    check_key_file 'db.env' "$DB_ENV_FILE" root '' 600 "${db_keys[@]}"
  else
    manual_result WARN 'db.env' "${DB_ENV_FILE} missing: setup handoff only, the sites do not read it"
  fi
  local site_root
  for site in ampas guilds; do
    site_root="$AMPAS_ROOT"
    [[ "$site" == guilds ]] && site_root="$GUILDS_ROOT"
    check_key_file "${site} .env" "${site_root}/.env" '' www-data 640 "${WP_ENV_KEYS[@]}"
    # DB_PORT is optional: without it WordPress uses the default MySQL port.
    if [[ -f "${site_root}/.env" && -n "$(missing_key_names "${site_root}/.env" DB_PORT)" ]]; then
      manual_result WARN "${site} DB_PORT" "${site_root}/.env has no DB_PORT: WordPress uses the default port"
    fi
  done
  for site in ampas guilds; do
    site_root="$AMPAS_ROOT"
    [[ "$site" == guilds ]] && site_root="$GUILDS_ROOT"
    # auth.json only feeds Composer installs; the running site never reads it.
    if [[ -f "${site_root}/auth.json" ]]; then
      check_present "${site} auth.json" "${site_root}/auth.json"
    else
      manual_result WARN "${site} auth.json" "${site_root}/auth.json missing: only Composer installs need it"
    fi
  done
  check_auth_file "$environment"
  check_ssh_aliases
  check_checkout_owners
}

# ---- PHP per site ----------------------------------------------------------

PHP_LINES=()
PHP_PROBLEMS=()
declare -A PHP_SETTING=()

# php_result <ok|FAIL|info> <label> <detail>; FAIL is drift.
php_result() {
  PHP_LINES+=("$(printf '  %-4s  %-16s %s' "$1" "$2" "$3")")
  if [[ "$1" == FAIL ]]; then
    PHP_PROBLEMS+=("${2}: ${3}")
  fi
}

# unit_state <unit>: "<active> <enabled>", each "unknown" when systemd has no answer.
unit_state() {
  local active enabled
  active="$(systemctl is-active "$1" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  printf '%s %s' "${active:-unknown}" "${enabled:-unknown}"
}

check_php_site() {
  local site="$1" version pool socket listen state
  version="${PHP_SETTING[${site}_version]:-}"
  pool="${PHP_SETTING[${site}_pool]:-}"
  socket="${PHP_SETTING[${site}_socket]:-}"
  if [[ -z "$version" || -z "$pool" || -z "$socket" ]]; then
    php_result FAIL "${site} pool" "no version, pool or socket in ${PHP_SETTINGS_FILE}"
    return
  fi
  if [[ ! -f "$pool" ]]; then
    php_result FAIL "${site} pool" "PHP ${version}: ${pool} missing"
    return
  fi
  listen="$(awk -F' = ' '$1 == "listen" { print $2 }' "$pool")"
  state="$(unit_state "php${version}-fpm")"
  if [[ "$listen" != "$socket" ]]; then
    php_result FAIL "${site} pool" "PHP ${version}: ${pool} listens on ${listen:-nothing}, want ${socket}"
  elif [[ ! -S "$socket" ]]; then
    php_result FAIL "${site} pool" "PHP ${version}: ${pool}, socket ${socket} absent (php${version}-fpm ${state})"
  else
    php_result ok "${site} pool" "PHP ${version}: ${pool}, socket ${socket}"
  fi
}

# check_php_version <pool.d dir>: one installed version's unit and pools. An
# FPM with a site configured on it runs and is enabled; any other is stopped
# and disabled. A site's pool under a version it is not configured on is stale.
check_php_version() {
  local dir="$1" version unit state site pool want_active=false
  local pools='' stale=''
  version="${dir#/etc/php/}"
  version="${version%/fpm/pool.d}"
  unit="php${version}-fpm"
  for site in "${PHP_SITES[@]}"; do
    if [[ "${PHP_SETTING[${site}_version]:-}" == "$version" ]]; then
      want_active=true
    fi
  done
  for pool in "$dir"/*.conf; do
    [[ -e "$pool" ]] || continue
    site="$(basename "$pool" .conf)"
    pools+="${pools:+ }${site}"
    if [[ "${PHP_SETTING[${site}_version]:-}" != "$version" ]]; then
      stale+="${stale:+ }${site}"
    fi
  done
  state="$(unit_state "$unit")"
  if [[ -n "$stale" ]]; then
    php_result FAIL "$unit" "${state}; pools left behind: ${stale}"
  elif [[ "$want_active" == true && "$state" != 'active enabled' ]]; then
    php_result FAIL "$unit" "${state}, want active enabled; pools: ${pools:-none}"
  elif [[ "$want_active" == false && -x "/usr/sbin/php-fpm${version}" \
    && "$state" != 'inactive disabled' ]]; then
    php_result FAIL "$unit" "${state}, want inactive disabled: no site uses PHP ${version}"
  else
    php_result ok "$unit" "${state}; pools: ${pools:-none}"
  fi
}

# Installed php* packages by version, any configured package not installed, and
# any installed version no site or the CLI uses (converge purges those).
check_php_packages() {
  local version count versions package
  local -a installed=() missing=()
  mapfile -t installed < <(dpkg-query -W -f '${db:Status-Abbrev}${Package} ${Version}\n' 'php*' 2>/dev/null \
    | awk '$1 == "ii" { print $2, $3 }' || true)
  while IFS= read -r version; do
    [[ -n "$version" ]] || continue
    count="$(printf '%s\n' "${installed[@]}" | grep -c "^php${version}-" || true)"
    versions="$(printf '%s\n' "${installed[@]}" | awk -v prefix="php${version}-" \
      'index($1, prefix) == 1 { print $2 }' | sort -u | paste -sd ' ' -)"
    if [[ " ${PHP_SETTING[packages]:-} " == *" php${version}-"* ]]; then
      php_result info "php${version} packages" "${count} installed: ${versions:-none}"
    else
      php_result FAIL "php${version} packages" "${count} installed (${versions:-none}), but no site or the CLI uses PHP ${version}"
    fi
  done < <(printf '%s\n' "${installed[@]}" | sed -nE 's/^php([0-9]+\.[0-9]+)-.*/\1/p' | sort -uV)
  for package in ${PHP_SETTING[packages]:-}; do
    if ! printf '%s\n' "${installed[@]}" | grep -q "^${package} "; then
      missing+=("$package")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    php_result FAIL 'php packages' "configured but not installed: ${missing[*]}"
  fi
}

check_php_cli() {
  local cli="${PHP_SETTING[cli_version]:-}" name want value
  if [[ -z "$cli" ]]; then
    php_result FAIL 'php cli' "no cli_version in ${PHP_SETTINGS_FILE}"
    return
  fi
  for name in "${PHP_CLI_ALTERNATIVES[@]}"; do
    want="/usr/bin/${name}${cli}"
    value="$(update-alternatives --query "$name" 2>/dev/null | awk '$1 == "Value:" { print $2 }' || true)"
    if [[ "$value" != "$want" ]]; then
      php_result FAIL "${name} cli" "/usr/bin/${name} is ${value:-not set}, want ${want}"
    else
      php_result ok "${name} cli" "/usr/bin/${name} -> ${value}"
    fi
  done
}

run_php_checks() {
  local key value site dir
  if [[ ! -r "$PHP_SETTINGS_FILE" ]]; then
    php_result FAIL 'php settings' "${PHP_SETTINGS_FILE} missing: converge has not applied per-site PHP"
    return
  fi
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] && PHP_SETTING["$key"]="$value"
  done < "$PHP_SETTINGS_FILE"
  for site in "${PHP_SITES[@]}"; do
    check_php_site "$site"
  done
  for dir in /etc/php/*/fpm/pool.d; do
    [[ -d "$dir" ]] || continue
    check_php_version "$dir"
  done
  check_php_packages
  check_php_cli
}

# One line naming each site's configured version and the CLI's.
php_summary() {
  local site summary=''
  for site in "${PHP_SITES[@]}"; do
    summary+="${summary:+, }${site} ${PHP_SETTING[${site}_version]:-unknown}"
  done
  printf '%s, cli %s: %d problems' "$summary" "${PHP_SETTING[cli_version]:-unknown}" "${#PHP_PROBLEMS[@]}"
}

# ---- OS patches ------------------------------------------------------------
# The policy (infra/README.md, "OS patches"): unattended-upgrades installs the
# security pocket every day. noble-updates, PHP from packages.sury.org, kernels and reboots
# wait for the monthly patch window. Status reports what is waiting.

PATCH_LINES=()
PATCH_PROBLEMS=()
PATCH_WARNED=0
REBOOT_REQUIRED_FILE='/var/run/reboot-required'
# apt.systemd.daily touches this after each successful list refresh.
APT_UPDATE_STAMP='/var/lib/apt/periodic/update-success-stamp'
APT_STAMP_MAX_AGE_HOURS=48
# More installed kernel images than this means the window skipped the cleanup.
KERNEL_IMAGES_MAX=3

# patch_result <ok|WARN|FAIL|info> <label> <detail>; FAIL is drift.
patch_result() {
  PATCH_LINES+=("$(printf '  %-4s  %-16s %s' "$1" "$2" "$3")")
  case "$1" in
    FAIL) PATCH_PROBLEMS+=("${2}: ${3}") ;;
    WARN) PATCH_WARNED=$((PATCH_WARNED + 1)) ;;
  esac
}

# pending_upgrades: "<class> <package>" for each upgrade apt would install now,
# from the cached lists. The class is security, php or other. A simulation:
# nothing is locked, downloaded or changed.
pending_upgrades() {
  apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | awk '
    $1 != "Inst" { next }
    /-security[ ,]/ { print "security", $2; next }
    $2 ~ /^php/ { print "php", $2; next }
    { print "other", $2 }' || true
}

check_automatic_updates() {
  local timer list_timer periodic origins
  timer="$(unit_state apt-daily-upgrade.timer)"
  list_timer="$(unit_state apt-daily.timer)"
  periodic="$(apt-config dump 2>/dev/null \
    | awk -F'"' '$1 == "APT::Periodic::Unattended-Upgrade " { print $2 }' || true)"
  origins="$(apt-config dump 2>/dev/null \
    | grep -cE '^Unattended-Upgrade::(Allowed-Origins|Origins-Pattern):: ".*security' || true)"
  if [[ "$timer" != 'active enabled' || "$list_timer" != 'active enabled' ]]; then
    patch_result FAIL 'auto updates' "apt-daily-upgrade.timer ${timer}, apt-daily.timer ${list_timer}, want active enabled"
  elif [[ "$periodic" != 1 ]]; then
    patch_result FAIL 'auto updates' "APT::Periodic::Unattended-Upgrade is ${periodic:-unset}, want 1"
  elif [[ "${origins:-0}" -eq 0 ]]; then
    patch_result FAIL 'auto updates' 'unattended-upgrades allows no security origin'
  else
    patch_result ok 'auto updates' "daily; ${origins} security origins allowed"
  fi
}

check_apt_lists() {
  local stamp age_hours
  if [[ ! -e "$APT_UPDATE_STAMP" ]]; then
    patch_result WARN 'package lists' "${APT_UPDATE_STAMP} missing: no successful daily refresh recorded"
    return
  fi
  stamp="$(stat -c '%Y' "$APT_UPDATE_STAMP")"
  age_hours=$(( ($(date +%s) - stamp) / 3600 ))
  if [[ "$age_hours" -gt "$APT_STAMP_MAX_AGE_HOURS" ]]; then
    patch_result WARN 'package lists' "last refreshed ${age_hours}h ago: the daily job has stopped refreshing"
  else
    patch_result ok 'package lists' "refreshed ${age_hours}h ago"
  fi
}

check_pending_upgrades() {
  local class package security=0 other=0
  local -a php=()
  while read -r class package; do
    case "$class" in
      security) security=$((security + 1)) ;;
      php) php+=("$package") ;;
      other) other=$((other + 1)) ;;
    esac
  done < <(pending_upgrades)
  if [[ "$security" -gt 0 ]]; then
    patch_result WARN 'security' "${security} waiting: the daily job installs these; read /var/log/unattended-upgrades"
  else
    patch_result ok 'security' 'none waiting'
  fi
  patch_result info 'updates' "${other} waiting for the patch window"
  if [[ ${#php[@]} -gt 0 ]]; then
    patch_result info 'php' "${#php[@]} waiting for the patch window: ${php[*]}"
  else
    patch_result ok 'php' 'none waiting'
  fi
}

check_reboot() {
  local packages=''
  if [[ -e "$REBOOT_REQUIRED_FILE" ]]; then
    if [[ -r "${REBOOT_REQUIRED_FILE}.pkgs" ]]; then
      packages="$(sort -u "${REBOOT_REQUIRED_FILE}.pkgs" | paste -sd ' ' -)"
    fi
    patch_result WARN 'reboot' "required${packages:+ by ${packages}}"
  else
    patch_result ok 'reboot' 'not required'
  fi
}

check_kernels() {
  local running count
  running="$(uname -r)"
  count="$(dpkg-query -W -f '${db:Status-Abbrev}${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
    | grep -c '^ii ' || true)"
  if [[ "${count:-0}" -gt "$KERNEL_IMAGES_MAX" ]]; then
    patch_result WARN 'kernels' "running ${running}; ${count} images installed, remove old ones in the patch window"
  else
    patch_result ok 'kernels' "running ${running}; ${count} images installed"
  fi
}

run_patch_checks() {
  check_automatic_updates
  check_apt_lists
  check_pending_upgrades
  check_reboot
  check_kernels
}

# ---- Time zones ------------------------------------------------------------
# PHP, the host and the databases all run in UTC. Pacific time belongs in code
# that names it, never in a server default. Any other zone is drift.

ZONE_LINES=()
ZONE_PROBLEMS=()
ZONE_WARNED=0

# zone_result <ok|WARN|FAIL> <label> <detail>; FAIL is drift.
zone_result() {
  ZONE_LINES+=("$(printf '  %-4s  %-16s %s' "$1" "$2" "$3")")
  case "$1" in
    FAIL) ZONE_PROBLEMS+=("${2}: ${3}") ;;
    WARN) ZONE_WARNED=$((ZONE_WARNED + 1)) ;;
  esac
}

is_utc() {
  case "$1" in
    UTC | Etc/UTC | +00:00) return 0 ;;
  esac
  return 1
}

# check_zone <label> <zone>
check_zone() {
  if is_utc "$2"; then
    zone_result ok "$1" "$2"
  else
    zone_result FAIL "$1" "${2:-unknown}, want UTC"
  fi
}

# db_zones <wp|rsvp> <path>: "<global> <session> <system>" from the database
# behind a site's own login, or "error <reason>". The login is read from the
# site's .env, or RSVP's secrets.json beside its database.php (an older
# database.php holds it literally). Nothing prints a credential.
db_zones() {
  php -d display_errors=0 -d log_errors=0 -- "$1" "$2" <<'PHP' 2>/dev/null || printf 'error php\n'
<?php
[, $kind, $path] = $argv + [null, '', ''];
$login = null;
if ($kind === 'wp') {
    $env = [];
    foreach ((is_readable($path) ? file($path, FILE_IGNORE_NEW_LINES) : []) as $line) {
        if (preg_match('/^\s*([A-Z_]+)\s*=\s*(.*)$/', $line, $m)) {
            $value = trim($m[2]);
            if (strlen($value) >= 2 && ($value[0] === "'" || $value[0] === '"') && substr($value, -1) === $value[0]) {
                $value = substr($value, 1, -1);
            }
            $env[$m[1]] = $value;
        }
    }
    if (isset($env['DB_HOST'], $env['DB_USER'], $env['DB_PASSWORD'], $env['DB_NAME'])) {
        // Like WordPress: DB_HOST, with any port in it; DB_PORT is not read.
        $login = [$env['DB_HOST'], $env['DB_USER'], $env['DB_PASSWORD'], $env['DB_NAME'], 3306];
    }
} else {
    $secrets = dirname($path) . '/secrets.json';
    if (is_readable($secrets)) {
        $s = json_decode((string) file_get_contents($secrets), true);
        if (is_array($s) && isset($s['db_hostname'], $s['db_username'], $s['db_password'], $s['db_database'])) {
            $login = [$s['db_hostname'], $s['db_username'], $s['db_password'], $s['db_database'], 3306];
        }
    } elseif (is_readable($path)) {
        define('BASEPATH', '/nonexistent/');
        $db = [];
        try {
            include $path;
        } catch (Throwable $e) {
            $db = [];
        }
        $d = $db['default'] ?? [];
        if (isset($d['hostname'], $d['username'], $d['password'], $d['database'])) {
            $login = [$d['hostname'], $d['username'], $d['password'], $d['database'], (int) ($d['port'] ?? 3306)];
        }
    }
}
if ($login === null) {
    exit("error no-login\n");
}
[$host, $user, $pass, $name, $port] = $login;
if (preg_match('/^(.+):(\d+)$/', $host, $m)) {
    [$host, $port] = [$m[1], (int) $m[2]];
}
mysqli_report(MYSQLI_REPORT_OFF);
$c = mysqli_init();
$c->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
if (!@$c->real_connect($host, $user, $pass, $name, $port)) {
    exit('error connect-' . mysqli_connect_errno() . "\n");
}
$r = $c->query('SELECT @@global.time_zone, @@session.time_zone, @@system_time_zone');
$row = $r ? $r->fetch_row() : null;
echo $row ? implode(' ', $row) . "\n" : "error query\n";
PHP
}

check_host_zone() {
  check_zone 'host' "$(timedatectl show -p Timezone --value 2>/dev/null || true)"
}

check_php_zones() {
  local version site
  local -a versions=()
  check_zone 'php cli' "$(php -r 'echo date_default_timezone_get();' 2>/dev/null || true)"
  for site in "${PHP_SITES[@]}"; do
    version="${PHP_SETTING[${site}_version]:-}"
    if [[ -n "$version" && " ${versions[*]} " != *" ${version} "* ]]; then
      versions+=("$version")
    fi
  done
  for version in "${versions[@]}"; do
    check_zone "php${version} fpm" "$("php-fpm${version}" -i 2>/dev/null \
      | awk -F' => ' '$1 == "date.timezone" { print $2; exit }' || true)"
  done
}

# check_db_zone <site> <wp|rsvp> <path>
check_db_zone() {
  local site="$1" global session system
  read -r global session system < <(db_zones "$2" "$3") || true
  if [[ "$global" == error ]]; then
    zone_result WARN "${site} db" "not read (${session:-unknown}): no login or no connection"
    return
  fi
  [[ "$global" == SYSTEM ]] && global="$system"
  [[ "$session" == SYSTEM ]] && session="$system"
  if is_utc "$global" && is_utc "$session"; then
    zone_result ok "${site} db" "global ${global}, session ${session}"
  else
    zone_result FAIL "${site} db" "global ${global:-unknown}, session ${session:-unknown}, want UTC: a Lightsail parameter change"
  fi
}

run_zone_checks() {
  local environment="$1"
  check_host_zone
  check_php_zones
  check_db_zone rsvp rsvp "${RSVP_ROOT}/admin/application/config/${environment}/database.php"
  check_db_zone ampas wp "${AMPAS_ROOT}/.env"
  check_db_zone guilds wp "${GUILDS_ROOT}/.env"
}

converge_status() {
  local short="$1"
  local environment ref key value line verdict
  local applied_sha='' applied_ref='' applied_env='' applied_at='' remote_sha='' checkout_sha='' checkout_state
  local manifest_state='present' manifest_note='' owned_ok=0
  local -a changed_files=() missing_files=() drift_reasons=()

  environment="$(read_setting "$ENVIRONMENT_FILE" staging)"
  ref="$(read_setting "$REF_FILE" develop)"

  if [[ -f "$APPLIED_FILE" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        sha) applied_sha="$value" ;;
        ref) applied_ref="$value" ;;
        environment) applied_env="$value" ;;
        applied_at) applied_at="$value" ;;
      esac
    done < "$APPLIED_FILE"
  fi

  # The same commit renders different staging and production configs, so a
  # matching SHA proves nothing unless the marker names this environment.
  if [[ -n "$applied_sha" ]]; then
    if [[ -z "$applied_env" ]]; then
      drift_reasons+=("applied environment unknown: ${APPLIED_FILE} has no environment line")
    elif [[ "$applied_env" != "$environment" ]]; then
      drift_reasons+=("applied environment is ${applied_env}, this instance is ${environment}: converge to re-render")
    fi
  fi

  if [[ -d "${AMAZON_SERVER_ROOT}/.git" ]]; then
    remote_sha="$(timeout 20 git -C "$AMAZON_SERVER_ROOT" ls-remote origin "refs/heads/${ref}" 2>/dev/null \
      | awk 'NR == 1 { print $1 }' || true)"
    checkout_sha="$(git -C "$AMAZON_SERVER_ROOT" rev-parse HEAD 2>/dev/null || true)"
    if checkout_is_dirty; then
      checkout_state='dirty'
    else
      checkout_state='clean'
    fi
  else
    checkout_state='missing'
  fi

  # Every manifest line must come back as OK, FAILED or FAILED open or read.
  # An empty, unreadable or malformed manifest, or a check that fails without
  # naming a file, means the owned files were not checked, so it is never CURRENT.
  local manifest_entries=0 manifest_checked=0 check_output='' check_rc=0
  if [[ ! -f "$MANIFEST_FILE" ]]; then
    manifest_state='missing'
    drift_reasons+=("manifest missing: ${MANIFEST_FILE}")
  elif [[ ! -r "$MANIFEST_FILE" ]]; then
    manifest_state='unreadable'
    drift_reasons+=("manifest unreadable: ${MANIFEST_FILE}")
  else
    manifest_entries="$(grep -c '[^[:space:]]' "$MANIFEST_FILE" || true)"
    check_output="$(sha256sum --check --strict "$MANIFEST_FILE" 2>&1)" || check_rc=$?
    while IFS= read -r line; do
      case "$line" in
        "sha256sum: ${MANIFEST_FILE}: "* | *'improperly formatted'*)
          manifest_note="${manifest_note:-${line#sha256sum: }}"
          ;;
        'sha256sum: '*) ;;
        *': OK') owned_ok=$((owned_ok + 1)) ;;
        *': FAILED open or read') missing_files+=("${line%: FAILED open or read}") ;;
        *': FAILED') changed_files+=("${line%: FAILED}") ;;
      esac
    done <<< "$check_output"
    manifest_checked=$((owned_ok + ${#changed_files[@]} + ${#missing_files[@]}))
    if [[ "${manifest_entries:-0}" -eq 0 ]]; then
      manifest_state='empty'
      drift_reasons+=("manifest empty: ${MANIFEST_FILE} lists no owned file")
    elif [[ "$manifest_checked" -ne "$manifest_entries" ]]; then
      manifest_state='malformed'
      drift_reasons+=("manifest malformed: ${manifest_checked} of ${manifest_entries} lines checked${manifest_note:+ (${manifest_note})}")
    elif [[ "$check_rc" -ne 0 && ${#changed_files[@]} -eq 0 && ${#missing_files[@]} -eq 0 ]]; then
      manifest_state='failed'
      drift_reasons+=("manifest check failed: sha256sum exit ${check_rc}${manifest_note:+ (${manifest_note})}")
    fi
  fi

  run_manual_checks "$environment"
  run_php_checks
  for line in "${PHP_PROBLEMS[@]}"; do
    drift_reasons+=("$line")
  done
  run_patch_checks
  for line in "${PATCH_PROBLEMS[@]}"; do
    drift_reasons+=("$line")
  done
  run_zone_checks "$environment"
  for line in "${ZONE_PROBLEMS[@]}"; do
    drift_reasons+=("$line")
  done

  if [[ -z "$applied_sha" ]]; then
    verdict='UNAPPLIED'
  elif [[ ${#drift_reasons[@]} -gt 0 || ${#changed_files[@]} -gt 0 || ${#missing_files[@]} -gt 0 \
    || "$checkout_state" != 'clean' || "$MANUAL_FAILED" -gt 0 ]]; then
    verdict='DRIFT'
  elif [[ "$remote_sha" != "$applied_sha" ]]; then
    verdict='BEHIND'
  else
    verdict='CURRENT'
  fi

  if [[ "$short" == true ]]; then
    local applied_short="${applied_sha:0:7}" remote_short="${remote_sha:0:7}" reasons=''
    for line in "${drift_reasons[@]}"; do
      reasons+="; ${line}"
    done
    printf '%s: %s (applied %s, remote %s, owned %d changed %d missing, manual %d failed %d warned, patches %d failed %d warned, zones %d failed %d warned)%s\n' \
      "$environment" "$verdict" "${applied_short:-none}" "${remote_short:-unreachable}" \
      "${#changed_files[@]}" "${#missing_files[@]}" "$MANUAL_FAILED" "$MANUAL_WARNED" \
      "${#PATCH_PROBLEMS[@]}" "$PATCH_WARNED" "${#ZONE_PROBLEMS[@]}" "$ZONE_WARNED" "$reasons"
  else
    printf '%-12s %s\n' environment "$environment" ref "$ref"
    if [[ -n "$applied_sha" ]]; then
      printf '%-12s %s %s (%s, %s)\n' applied "${applied_sha:0:7}" "$applied_at" \
        "$applied_ref" "${applied_env:-environment unknown}"
    else
      printf '%-12s %s\n' applied "none (${APPLIED_FILE} absent)"
    fi
    if [[ -n "$remote_sha" ]]; then
      printf '%-12s %s\n' remote "${remote_sha:0:7}"
    else
      printf '%-12s %s\n' remote "unreachable (refs/heads/${ref} not read)"
    fi
    printf '%-12s %s %s\n' checkout "${checkout_sha:0:7}" "$checkout_state"
    if [[ "$manifest_state" != 'present' ]]; then
      printf '%-12s %s\n' 'owned files' "not checked: manifest ${manifest_state} (${MANIFEST_FILE})"
    else
      printf '%-12s %d match, %d changed, %d missing\n' 'owned files' \
        "$owned_ok" "${#changed_files[@]}" "${#missing_files[@]}"
    fi
    for line in "${changed_files[@]}"; do
      printf '  changed  %s\n' "$line"
    done
    for line in "${missing_files[@]}"; do
      printf '  missing  %s\n' "$line"
    done
    printf '%-12s %s\n' php "$(php_summary)"
    printf '%s\n' "${PHP_LINES[@]}"
    printf '%-12s %d failed, %d warned\n' patches "${#PATCH_PROBLEMS[@]}" "$PATCH_WARNED"
    printf '%s\n' "${PATCH_LINES[@]}"
    printf '%-12s %d failed, %d warned\n' zones "${#ZONE_PROBLEMS[@]}" "$ZONE_WARNED"
    printf '%s\n' "${ZONE_LINES[@]}"
    printf '%-12s %d failed, %d warned\n' manual "$MANUAL_FAILED" "$MANUAL_WARNED"
    printf '%s\n' "${MANUAL_LINES[@]}"
    for line in "${drift_reasons[@]}"; do
      printf '%-12s %s\n' problem "$line"
    done
    printf '%-12s %s\n' verdict "$verdict"
  fi

  [[ "$verdict" == 'CURRENT' ]]
}

main() {
  if [[ ${EUID} -ne 0 ]]; then
    die 'must run as root (sudo)'
  fi
  case "${1:-}" in
    '') converge_apply ;;
    status)
      case "${2:-}" in
        '') converge_status false ;;
        --short) converge_status true ;;
        *) usage ;;
      esac
      ;;
    -h | --help) usage 0 ;;
    *) usage ;;
  esac
}

# Tests source this file for its functions; only a direct run acts.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
