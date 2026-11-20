# shellcheck shell=bash
# Staging's local MySQL server and the swap file that guards it. Sourced by
# infra/cloud-init.sh. mysql_local_converge acts on staging only, so a
# production converge never installs a database server.
#
# The server loads mysql/server-parity.cnf as is, so staging keeps the managed
# servers' sql_mode, character set, collation and time zone, then
# mysql/staging-local.cnf for what differs on a shared host: local-only
# listeners and a small buffer pool. infra/converge.sh status reads both
# installed files back and compares them with the running server.

MYSQL_CONF_DIR='/etc/mysql/mysql.conf.d'
MYSQL_PARITY_CONF="${MYSQL_CONF_DIR}/zz-amazon-parity.cnf"
MYSQL_LOCAL_CONF="${MYSQL_CONF_DIR}/zz-amazon-staging.cnf"
MYSQL_PACKAGES=(mysql-server-8.0 mysql-client-8.0)
SWAP_FILE='/swapfile'
SWAP_SIZE='1G'

# swap_ensure: a 1 GiB swap file, active now and at boot. It guards against the
# out-of-memory killer when MySQL and PHP-FPM peak together; it is not working
# space.
swap_ensure() {
  if [[ ! -f "$SWAP_FILE" ]]; then
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" > /dev/null
  fi
  if ! grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
  fi
  if ! swapon --show=NAME --noheadings | grep -qxF "$SWAP_FILE"; then
    swapon "$SWAP_FILE"
  fi
}

# mysql_local_converge: on staging, the swap file, both config files, the
# server and client packages, and a running server. The config goes in before
# the packages, so a first install starts on it; a later config change restarts
# the server, and an unchanged one leaves it running.
mysql_local_converge() {
  local before after was_installed=false
  [[ "$AMAZON_SERVER_ENVIRONMENT" == 'staging' ]] || return 0

  swap_ensure

  # Absent files on a first run hash as empty input.
  before="$({ cat "$MYSQL_PARITY_CONF" "$MYSQL_LOCAL_CONF" 2> /dev/null || true; } | sha256sum)"
  install -d -o root -g root -m 0755 "$MYSQL_CONF_DIR"
  install -o root -g root -m 0644 "${AMAZON_SERVER_ROOT}/mysql/server-parity.cnf" "$MYSQL_PARITY_CONF"
  install -o root -g root -m 0644 "${AMAZON_SERVER_ROOT}/mysql/staging-local.cnf" "$MYSQL_LOCAL_CONF"
  own_file "$MYSQL_PARITY_CONF" "$MYSQL_LOCAL_CONF"
  after="$(cat "$MYSQL_PARITY_CONF" "$MYSQL_LOCAL_CONF" | sha256sum)"

  if dpkg-query -W -f='${Status}' mysql-server-8.0 2> /dev/null | grep -q 'install ok installed'; then
    was_installed=true
  fi
  apt-get install -y "${MYSQL_PACKAGES[@]}"
  if [[ "$was_installed" == true && "$before" != "$after" ]]; then
    systemctl restart mysql
  fi
  systemctl enable --now mysql
}
