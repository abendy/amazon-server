# shellcheck shell=bash
# PHP for each site: sockets, pools, packages, apt pins, FPM units and the CLI
# alternative, all derived from the versions infra/cloud-init.sh sets.
# cloud-init.sh sources this file; infra/tests/php-versions.sh sources it with
# a temporary PHP_SYSROOT and stubbed apt-get, systemctl and update-alternatives.
#
# The caller sets RSVP_PHP_VERSION, AMPAS_PHP_VERSION, GUILDS_PHP_VERSION,
# PHP_CLI_VERSION and PHP_FPM_LOG_ROOT, and defines own_file.

PHP_SITES=(rsvp ampas guilds)
PHP_SYSROOT="${PHP_SYSROOT:-}"
# Read by amazon-server-converge status and scripts/purge-theme-cache.sh.
PHP_SETTINGS_FILE="${PHP_SYSROOT}/etc/amazon-server.php-sites"

php_site_version() {
  case "$1" in
    rsvp) printf '%s' "$RSVP_PHP_VERSION" ;;
    ampas) printf '%s' "$AMPAS_PHP_VERSION" ;;
    guilds) printf '%s' "$GUILDS_PHP_VERSION" ;;
    *) printf 'php-sites.sh: unknown site %s\n' "$1" >&2; return 1 ;;
  esac
}

php_site_socket() {
  printf '/run/php/php%s-fpm-%s.sock' "$(php_site_version "$1")" "$1"
}

php_pool_dir() {
  printf '%s/etc/php/%s/fpm/pool.d' "$PHP_SYSROOT" "$1"
}

php_fpm_unit() {
  printf 'php%s-fpm' "$1"
}

# Versions with at least one site pool, oldest first.
php_fpm_versions() {
  local site
  for site in "${PHP_SITES[@]}"; do
    php_site_version "$site"
    printf '\n'
  done | sort -uV
}

# Versions to install: every site version plus the CLI version.
php_install_versions() {
  { php_fpm_versions; printf '%s\n' "$PHP_CLI_VERSION"; } | sort -uV
}

# Versions whose FPM is on disk, from a pool directory and the FPM binary.
php_installed_fpm_versions() {
  local dir version
  for dir in "$PHP_SYSROOT"/etc/php/*/fpm/pool.d; do
    [[ -d "$dir" ]] || continue
    version="${dir#"$PHP_SYSROOT"/etc/php/}"
    version="${version%/fpm/pool.d}"
    if [[ -x "${PHP_SYSROOT}/usr/sbin/php-fpm${version}" ]]; then
      printf '%s\n' "$version"
    fi
  done | sort -uV
}

php_packages() {
  local extension
  for extension in cli curl fpm gd intl mbstring mysql xml zip; do
    printf 'php%s-%s\n' "$1" "$extension"
  done
}

# One pin file per installed version; pins for versions no longer installed go.
php_write_apt_pins() {
  local preferences="${PHP_SYSROOT}/etc/apt/preferences.d" pin version
  local -a keep=()
  install -d -o root -g root -m 0755 "$preferences"
  while IFS= read -r version; do
    pin="${preferences}/amazon-php${version//./}"
    cat > "$pin" <<APT_PREFERENCE
Package: php${version}*
Pin: version ${version}.*
Pin-Priority: 1001
APT_PREFERENCE
    own_file "$pin"
    keep+=("$pin")
  done < <(php_install_versions)
  for pin in "$preferences"/amazon-php[0-9]*; do
    [[ -e "$pin" ]] || continue
    if ! printf '%s\n' "${keep[@]}" | grep -qxF -- "$pin"; then
      rm -f "$pin"
    fi
  done
}

# The CLI commands php-cli registers as alternatives. Installing a newer
# php-cli moves each of them to it (abendy/amazon-docs#398).
PHP_CLI_ALTERNATIVES=(php phar phar.phar)

# Installing a newer php-cli moves the CLI alternatives to it, so they are set
# back to the configured version right after the install.
php_install_packages() {
  local version name
  local -a packages=()
  while IFS= read -r version; do
    mapfile -t -O "${#packages[@]}" packages < <(php_packages "$version")
  done < <(php_install_versions)
  apt-get install -y "${packages[@]}"
  for name in "${PHP_CLI_ALTERNATIVES[@]}"; do
    update-alternatives --set "$name" "/usr/bin/${name}${PHP_CLI_VERSION}"
  done
}

# abendy/amazon-docs#370: every configured version runs in UTC.
php_write_timezone_ini() {
  local version dir ini
  while IFS= read -r version; do
    for dir in "${PHP_SYSROOT}/etc/php/${version}/fpm/conf.d" "${PHP_SYSROOT}/etc/php/${version}/cli/conf.d"; do
      [[ -d "$dir" ]] || continue
      ini="${dir}/zz-amazon-timezone.ini"
      printf 'date.timezone = UTC\n' > "$ini"
      own_file "$ini"
    done
  done < <(php_install_versions)
}

# CVE-2026-109619 (GHSA-6wmf-4rv5-p3rp): no site uses session upload progress,
# and the advisory says to keep it off after patching. FPM only: the CLI serves
# no web requests.
php_write_security_ini() {
  local version dir ini
  while IFS= read -r version; do
    dir="${PHP_SYSROOT}/etc/php/${version}/fpm/conf.d"
    [[ -d "$dir" ]] || continue
    ini="${dir}/zz-amazon-security.ini"
    printf '; CVE-2026-109619: no site uses upload progress. Keep off after patching.\nsession.upload_progress.enabled = 0\n' > "$ini"
    own_file "$ini"
  done < <(php_install_versions)
}

php_enable_units() {
  local version
  while IFS= read -r version; do
    systemctl enable "$(php_fpm_unit "$version")"
  done < <(php_fpm_versions)
}

php_write_pool() {
  local pool_name="$1"
  local pool_file
  pool_file="$(php_pool_dir "$(php_site_version "$pool_name")")/${pool_name}.conf"

  cat > "$pool_file" <<POOL
[${pool_name}]
user = www-data
group = www-data
listen = $(php_site_socket "$pool_name")
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
php_admin_value[error_log] = ${PHP_FPM_LOG_ROOT}/${pool_name}-error.log
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[max_execution_time] = 600
php_admin_value[max_input_time] = 600
POOL
  own_file "$pool_file"
}

# What converge applied, for status and the cache purge. key=value lines.
php_write_settings() {
  local site version
  local -a packages=()
  while IFS= read -r version; do
    mapfile -t -O "${#packages[@]}" packages < <(php_packages "$version")
  done < <(php_install_versions)
  {
    for site in "${PHP_SITES[@]}"; do
      version="$(php_site_version "$site")"
      printf '%s_version=%s\n' "$site" "$version"
      printf '%s_pool=%s/%s.conf\n' "$site" "/etc/php/${version}/fpm/pool.d" "$site"
      printf '%s_socket=%s\n' "$site" "$(php_site_socket "$site")"
      printf '%s_php=/usr/bin/php%s\n' "$site" "$version"
    done
    printf 'cli_version=%s\n' "$PHP_CLI_VERSION"
    printf 'cli_php=/usr/bin/php%s\n' "$PHP_CLI_VERSION"
    printf 'packages=%s\n' "${packages[*]}"
  } > "$PHP_SETTINGS_FILE"
  chmod 0644 "$PHP_SETTINGS_FILE"
  own_file "$PHP_SETTINGS_FILE"
}

# abendy/amazon-docs#397: a restart cuts off uploads and long requests in
# flight, so converge restarts an FPM only when its packages or ini changed, or
# when it is not running; a change to pool files alone gets a graceful reload;
# nothing changed, nothing happens. Fingerprints taken before any PHP step
# (php_snapshot_fpm_state) are compared with the state after the writes.
declare -A PHP_FPM_RESTART_BEFORE=()
declare -A PHP_FPM_POOLS_BEFORE=()

# Packages, their versions, php.ini, php-fpm.conf and conf.d: a change needs a restart.
php_fpm_restart_state() {
  local etc="${PHP_SYSROOT}/etc/php/${1}/fpm" file
  {
    dpkg-query -W -f '${Package} ${Version}\n' "php${1}*" 2>/dev/null || true
    for file in "${etc}/php.ini" "${etc}/php-fpm.conf" "${etc}"/conf.d/*.ini; do
      if [[ -f "$file" ]]; then
        printf '%s\n' "$file"
        cat "$file"
      fi
    done
  } | sha256sum
}

# The pool files: a change needs only a reload.
php_fpm_pool_state() {
  local file
  for file in "$(php_pool_dir "$1")"/*.conf; do
    if [[ -f "$file" ]]; then
      printf '%s\n' "$file"
      cat "$file"
    fi
  done | sha256sum
}

php_snapshot_fpm_state() {
  local dir version
  for dir in "$PHP_SYSROOT"/etc/php/*/fpm; do
    [[ -d "$dir" ]] || continue
    version="${dir#"$PHP_SYSROOT"/etc/php/}"
    version="${version%/fpm}"
    PHP_FPM_RESTART_BEFORE["$version"]="$(php_fpm_restart_state "$version")"
    PHP_FPM_POOLS_BEFORE["$version"]="$(php_fpm_pool_state "$version")"
  done
}

# php_apply_fpm <version>: restart, reload or leave one FPM, by what changed.
php_apply_fpm() {
  local version="$1" unit
  unit="$(php_fpm_unit "$version")"
  if ! systemctl is-active --quiet "$unit" \
    || [[ "$(php_fpm_restart_state "$version")" != "${PHP_FPM_RESTART_BEFORE[$version]:-}" ]]; then
    systemctl restart "$unit"
  elif [[ "$(php_fpm_pool_state "$version")" != "${PHP_FPM_POOLS_BEFORE[$version]:-}" ]]; then
    systemctl reload "$unit"
  fi
}

# Before nginx renders: each site's pool goes in its own version's pool.d, and
# each FPM with pools restarts or reloads as php_apply_fpm decides, so the new
# sockets exist before nginx points at them. The old version keeps a moved
# site's pool until php_retire_stale.
php_place_pools() {
  local dir site version
  for dir in "$PHP_SYSROOT"/etc/php/*/fpm/pool.d; do
    if [[ -d "$dir" ]]; then
      rm -f "${dir}/www.conf"
    fi
  done
  while IFS= read -r version; do
    install -d -o root -g root -m 0755 "$(php_pool_dir "$version")"
  done < <(php_fpm_versions)
  for site in "${PHP_SITES[@]}"; do
    php_write_pool "$site"
  done
  php_write_settings
  while IFS= read -r version; do
    php_apply_fpm "$version"
  done < <(php_fpm_versions)
}

# After nginx reloads onto the new sockets: delete each site's pool from every
# other version, reload an FPM that lost a pool, and stop and disable an
# installed FPM with no pools (FPM refuses to start with none). php_purge_unused
# then removes a version nothing uses.
php_retire_stale() {
  local dir site version pool
  local -a fpm_versions=() changed=()
  mapfile -t fpm_versions < <(php_fpm_versions)
  for dir in "$PHP_SYSROOT"/etc/php/*/fpm/pool.d; do
    [[ -d "$dir" ]] || continue
    version="${dir#"$PHP_SYSROOT"/etc/php/}"
    version="${version%/fpm/pool.d}"
    for site in "${PHP_SITES[@]}"; do
      pool="${dir}/${site}.conf"
      if [[ -e "$pool" && "$(php_site_version "$site")" != "$version" ]]; then
        rm -f "$pool"
        changed+=("$version")
      fi
    done
  done
  while IFS= read -r version; do
    if printf '%s\n' "${fpm_versions[@]}" | grep -qxF -- "$version"; then
      if printf '%s\n' "${changed[@]}" | grep -qxF -- "$version"; then
        systemctl reload "$(php_fpm_unit "$version")"
      fi
    else
      systemctl stop "$(php_fpm_unit "$version")"
      systemctl disable "$(php_fpm_unit "$version")"
    fi
  done < <(php_installed_fpm_versions)
}

# Every php<version> package dpkg still knows, installed or with config left.
php_dpkg_packages() {
  dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'php*' 2>/dev/null \
    | awk '$1 != "un" { print $2 }' \
    | grep -E "^php${1//./\\.}(-|$)" || true
}

# Versions with a php<version> package in dpkg or a directory under /etc/php.
php_present_versions() {
  local dir
  {
    dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'php*' 2>/dev/null \
      | awk '$1 != "un" { print $2 }' \
      | sed -nE 's/^php([0-9]+\.[0-9]+)(-.*)?$/\1/p' || true
    for dir in "$PHP_SYSROOT"/etc/php/*; do
      [[ -d "$dir" ]] && basename "$dir"
    done | grep -xE '[0-9]+\.[0-9]+' || true
  } | sort -uV
}

# After php_retire_stale: purge every version no site and not the CLI uses,
# then delete what converge wrote under its /etc/php, so nothing of it is left.
# Converge installs it again if a site or the CLI moves back to it.
php_purge_unused() {
  local version
  local -a keep=() packages=()
  mapfile -t keep < <(php_install_versions)
  while IFS= read -r version; do
    if printf '%s\n' "${keep[@]}" | grep -qxF -- "$version"; then
      continue
    fi
    mapfile -t packages < <(php_dpkg_packages "$version")
    if [[ ${#packages[@]} -gt 0 ]]; then
      apt-get purge -y "${packages[@]}"
    fi
    rm -rf "${PHP_SYSROOT}/etc/php/${version}"
  done < <(php_present_versions)
}
