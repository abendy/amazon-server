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

# Installing a newer php-cli moves the php alternative to it, so the CLI is
# set back to the configured version right after the install.
php_install_packages() {
  local version
  local -a packages=()
  while IFS= read -r version; do
    mapfile -t -O "${#packages[@]}" packages < <(php_packages "$version")
  done < <(php_install_versions)
  apt-get install -y "${packages[@]}"
  update-alternatives --set php "/usr/bin/php${PHP_CLI_VERSION}"
}

# abendy/amazon-docs#370: every installed version runs in UTC.
php_write_timezone_ini() {
  local dir ini
  for dir in "$PHP_SYSROOT"/etc/php/*/fpm/conf.d "$PHP_SYSROOT"/etc/php/*/cli/conf.d; do
    [[ -d "$dir" ]] || continue
    ini="${dir}/zz-amazon-timezone.ini"
    printf 'date.timezone = UTC\n' > "$ini"
    own_file "$ini"
  done
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

# Before nginx renders: each site's pool goes in its own version's pool.d and
# every FPM with pools restarts, so the new sockets exist before nginx points
# at them. The old version keeps a moved site's pool until php_retire_stale.
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
    systemctl restart "$(php_fpm_unit "$version")"
  done < <(php_fpm_versions)
}

# After nginx reloads onto the new sockets: delete each site's pool from every
# other version, restart an FPM that lost a pool, and stop and disable an
# installed FPM with no pools (FPM refuses to start with none). Packages stay.
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
        systemctl restart "$(php_fpm_unit "$version")"
      fi
    else
      systemctl stop "$(php_fpm_unit "$version")"
      systemctl disable "$(php_fpm_unit "$version")"
    fi
  done < <(php_installed_fpm_versions)
}
