# shellcheck shell=bash
# The encode review tool (Media → Optimize video) on staging. Sourced by
# infra/cloud-init.sh, like infra/mysql-local.sh. Both functions act on staging
# only, so a production converge installs and renders nothing for the tool.
#
#   encode_review_nginx  before the server blocks render: installs the snippet
#                        (playback)
#   encode_review_site_include  per WordPress server block: the include line
#   encode_review_converge  after nginx reloads: ffmpeg, the vmaf tool, the
#                        service user, the spool, the worker unit and the
#                        must-use plugin in each WordPress site
#
# infra/converge.sh status reads the installed state back (run_encode_review_checks).
# See encode-review/README.md.

ENCODE_REVIEW_USER='encode-review'
ENCODE_REVIEW_SPOOL='/srv/encode-review'
ENCODE_REVIEW_SPOOL_DIRS=(incoming queue work 'done' failed sends)
ENCODE_REVIEW_UNIT='encode-review-worker.service'
ENCODE_REVIEW_UNIT_FILE="/etc/systemd/system/${ENCODE_REVIEW_UNIT}"
ENCODE_REVIEW_DROPIN_DIR="/etc/systemd/system/${ENCODE_REVIEW_UNIT}.d"
ENCODE_REVIEW_CREDENTIAL_DROPIN="${ENCODE_REVIEW_DROPIN_DIR}/production-upload.conf"
# The production upload login (encode-review/README.md, "Send to production").
# Root-only, outside every repo; systemd hands it to the worker alone.
ENCODE_REVIEW_CREDENTIAL_FILE='/root/amazon-staging/encode-review-production.env'
ENCODE_REVIEW_NGINX_SNIPPET='/etc/nginx/snippets/encode-review.conf'
# needrestart (run by unattended upgrades) restarts services after a library
# update; for the worker that cuts off a running encode. It is left out, and
# picks up new libraries at its next restart (converge, or a reboot).
ENCODE_REVIEW_NEEDRESTART_CONF='/etc/needrestart/conf.d/encode-review.conf'
# What the running worker was last started with (encode_review_state_hash), so
# converge restarts it exactly when that changes. Root-only.
ENCODE_REVIEW_STATE_DIR='/var/lib/encode-review'
ENCODE_REVIEW_STATE_FILE="${ENCODE_REVIEW_STATE_DIR}/worker-state"
# Earlier builds sent whole uploads to a 5G PHP-FPM pool per site; uploads now
# go in parts through the site pool, and converge removes those pools.
ENCODE_REVIEW_UPLOAD_POOL_SUFFIX='encode-review-upload'
ENCODE_REVIEW_WP_SITES=(ampas guilds)
ENCODE_REVIEW_PLUGIN_SITES=(
  /var/www/html/amazon-studios-ampas
  /var/www/html/amazon-studios-guilds
)
ENCODE_REVIEW_PLUGIN_SUBDIR='web/app/mu-plugins/encode-review'

# Ubuntu 24.04's ffmpeg has no libvmaf filter, so scoring uses Netflix's own
# vmaf tool: the pinned upstream release build, checked against its SHA-256.
ENCODE_REVIEW_VMAF_VERSION='v3.2.1'
ENCODE_REVIEW_VMAF_BIN='/opt/encode-review/bin/vmaf'
declare -A ENCODE_REVIEW_VMAF_ZIP=(
  [x86_64]='vmaf-linux-x86_64-gcc.zip'
  [aarch64]='vmaf-linux-arm64-clang.zip'
)
declare -A ENCODE_REVIEW_VMAF_ZIP_SHA256=(
  [x86_64]='c0bb6d354f7009530fab5749e1309bd90f9c45a5a10e90250e6e558c48cfdd02'
  [aarch64]='94fddd3fa6440c68664d0498eb0716ae0808e2bae2ecede767deb6a30753c74e'
)

# Rendered into the staging WordPress server blocks (infra/cloud-init.sh,
# wp-http.conf.tpl and wp-https.conf.tpl). Empty on production, so its
# rendered files stay byte-identical.
SITE_ENCODE_REVIEW_INCLUDE=''

# encode_review_nginx: on staging, installs the snippet. Runs before the server
# blocks render and nginx -t.
encode_review_nginx() {
  SITE_ENCODE_REVIEW_INCLUDE=''
  export SITE_ENCODE_REVIEW_INCLUDE
  [[ "$AMAZON_SERVER_ENVIRONMENT" == 'staging' ]] || return 0
  install -o root -g root -m 0644 \
    "${AMAZON_SERVER_ROOT}/encode-review/nginx/encode-review.conf" "$ENCODE_REVIEW_NGINX_SNIPPET"
  own_file "$ENCODE_REVIEW_NGINX_SNIPPET"
}

# encode_review_site_include: sets the include line each WordPress server
# block renders. Empty on production.
encode_review_site_include() {
  SITE_ENCODE_REVIEW_INCLUDE=''
  if [[ "$AMAZON_SERVER_ENVIRONMENT" == 'staging' ]]; then
    SITE_ENCODE_REVIEW_INCLUDE="$(printf '\n\n  # Encode review, staging only (encode-review/README.md): playback.\n  include snippets/encode-review.conf;')"
  fi
  export SITE_ENCODE_REVIEW_INCLUDE
}

# encode_review_retire_upload_pools: removes the 5G upload pools earlier
# builds installed (<site>-encode-review-upload) from every PHP version and
# reloads each running FPM that had one. Prints nothing when there are none.
encode_review_retire_upload_pools() {
  local site file version
  local -a changed=()
  for site in "${ENCODE_REVIEW_WP_SITES[@]}"; do
    for file in "${PHP_SYSROOT:-}"/etc/php/*/fpm/pool.d/"${site}-${ENCODE_REVIEW_UPLOAD_POOL_SUFFIX}.conf"; do
      [[ -e "$file" ]] || continue
      rm -f "$file"
      version="${file#"${PHP_SYSROOT:-}"/etc/php/}"
      changed+=("${version%%/*}")
    done
  done
  [[ ${#changed[@]} -gt 0 ]] || return 0
  mapfile -t changed < <(printf '%s\n' "${changed[@]}" | sort -u)
  for version in "${changed[@]}"; do
    if systemctl is-active --quiet "$(php_fpm_unit "$version")"; then
      systemctl reload "$(php_fpm_unit "$version")"
    fi
  done
}

# encode_review_vmaf: the pinned vmaf tool. Downloads only when the installed
# binary is missing or is not the one the pinned archive holds.
encode_review_vmaf() {
  local arch zip_name zip_sha work
  arch="$(uname -m)"
  zip_name="${ENCODE_REVIEW_VMAF_ZIP[$arch]:-}"
  zip_sha="${ENCODE_REVIEW_VMAF_ZIP_SHA256[$arch]:-}"
  if [[ -z "$zip_name" ]]; then
    printf 'warning: encode review: no vmaf build for %s; scoring will fail\n' "$arch" >&2
    return 0
  fi
  if [[ -x "$ENCODE_REVIEW_VMAF_BIN" && -f "${ENCODE_REVIEW_VMAF_BIN}.zip-sha256" ]] \
    && [[ "$(cat "${ENCODE_REVIEW_VMAF_BIN}.zip-sha256")" == "$zip_sha" ]] \
    && "$ENCODE_REVIEW_VMAF_BIN" --version > /dev/null 2>&1; then
    return 0
  fi
  work="$(mktemp -d)"
  curl -fsSL --retry 3 -o "${work}/${zip_name}" \
    "https://github.com/Netflix/vmaf/releases/download/${ENCODE_REVIEW_VMAF_VERSION}/${zip_name}"
  if ! printf '%s  %s\n' "$zip_sha" "${work}/${zip_name}" | sha256sum --check --status; then
    rm -rf "$work"
    printf 'encode review: %s does not match its pinned SHA-256; vmaf not installed\n' "$zip_name" >&2
    return 1
  fi
  python3 -m zipfile -e "${work}/${zip_name}" "${work}/x"
  install -d -o root -g root -m 0755 "$(dirname "$ENCODE_REVIEW_VMAF_BIN")"
  install -o root -g root -m 0755 "${work}/x/vmaf" "$ENCODE_REVIEW_VMAF_BIN"
  printf '%s\n' "$zip_sha" > "${ENCODE_REVIEW_VMAF_BIN}.zip-sha256"
  rm -rf "$work"
}

# encode_review_state_hash [root unit-file dropin-dir credential-file]: one
# digest of everything the worker loads when it starts: the unit, its
# drop-ins, the worker code in the checkout and the production login (only
# its digest; the login itself is never printed). converge.sh status calls it
# with its own paths.
encode_review_state_hash() {
  local root="${1:-$AMAZON_SERVER_ROOT}" unit="${2:-$ENCODE_REVIEW_UNIT_FILE}"
  local dropins="${3:-$ENCODE_REVIEW_DROPIN_DIR}" credential="${4:-$ENCODE_REVIEW_CREDENTIAL_FILE}"
  {
    cat "$unit" "$dropins"/*.conf 2> /dev/null || true
    (cd "${root}/encode-review/worker" 2> /dev/null && find . -name '*.py' -type f -print0 \
      | sort -z | xargs -0 -r sha256sum) || true
    printf 'credential '
    sha256sum 2> /dev/null < "$credential" || printf 'none\n'
  } | sha256sum | cut -d' ' -f1
}

# encode_review_apply_worker: starts the worker, or restarts it exactly when it
# would load something else: new worker code in the checkout, a changed unit
# or drop-in, or an edited login file (systemd copies a credential only at
# start). An unchanged converge leaves a running encode alone. Records the
# digest the worker now runs with, root-only.
encode_review_apply_worker() {
  local desired recorded
  desired="$(encode_review_state_hash)"
  recorded="$(cat "$ENCODE_REVIEW_STATE_FILE" 2> /dev/null || true)"
  systemctl daemon-reload
  systemctl enable "$ENCODE_REVIEW_UNIT"
  if ! systemctl is-active --quiet "$ENCODE_REVIEW_UNIT"; then
    systemctl start "$ENCODE_REVIEW_UNIT"
  elif [[ "$desired" != "$recorded" ]]; then
    systemctl restart "$ENCODE_REVIEW_UNIT"
  fi
  install -d -m 0700 "$ENCODE_REVIEW_STATE_DIR"
  (umask 077 && printf '%s\n' "$desired" > "$ENCODE_REVIEW_STATE_FILE")
}

# encode_review_converge: on staging, everything the tool needs, in the order
# a first install needs it.
encode_review_converge() {
  local site docroot plugin_target group_changed=false
  [[ "$AMAZON_SERVER_ENVIRONMENT" == 'staging' ]] || return 0

  apt-get install -y ffmpeg
  encode_review_vmaf

  # The worker's own user. PHP-FPM (www-data) joins its group to write uploads
  # into the spool and read results; nginx only reads, which the modes allow.
  if ! id -u "$ENCODE_REVIEW_USER" > /dev/null 2>&1; then
    useradd --system --user-group --home-dir "$ENCODE_REVIEW_SPOOL" --no-create-home \
      --shell /usr/sbin/nologin "$ENCODE_REVIEW_USER"
  fi
  if ! id -nG www-data | tr ' ' '\n' | grep -qxF "$ENCODE_REVIEW_USER"; then
    usermod -aG "$ENCODE_REVIEW_USER" www-data
    group_changed=true
  fi

  # Setgid folders keep the group on everything either side creates.
  install -d -o "$ENCODE_REVIEW_USER" -g "$ENCODE_REVIEW_USER" -m 2775 "$ENCODE_REVIEW_SPOOL"
  for dir in "${ENCODE_REVIEW_SPOOL_DIRS[@]}"; do
    install -d -o "$ENCODE_REVIEW_USER" -g "$ENCODE_REVIEW_USER" -m 2775 "${ENCODE_REVIEW_SPOOL}/${dir}"
  done
  # Run 1's send folder, replaced by sends/. Removed once empty.
  if [[ -d "${ENCODE_REVIEW_SPOOL}/outbox" ]]; then
    rmdir --ignore-fail-on-non-empty "${ENCODE_REVIEW_SPOOL}/outbox"
  fi

  encode_review_retire_upload_pools
  install -d -o root -g root -m 0755 "$(dirname "$ENCODE_REVIEW_NEEDRESTART_CONF")"
  cat > "$ENCODE_REVIEW_NEEDRESTART_CONF" <<'CONF'
# Encode review (infra/encode-review.sh): never restart the worker after a
# library update; it would cut off a running encode.
$nrconf{override_rc}{qr(^encode-review-worker\.service$)} = 0;
CONF
  chmod 0644 "$ENCODE_REVIEW_NEEDRESTART_CONF"
  own_file "$ENCODE_REVIEW_NEEDRESTART_CONF"
  install -o root -g root -m 0644 \
    "${AMAZON_SERVER_ROOT}/encode-review/systemd/${ENCODE_REVIEW_UNIT}" "$ENCODE_REVIEW_UNIT_FILE"
  own_file "$ENCODE_REVIEW_UNIT_FILE"
  # The login reaches the worker only through systemd's credential store, and
  # only once the driver has placed it.
  if [[ -f "$ENCODE_REVIEW_CREDENTIAL_FILE" ]]; then
    chown root:root "$ENCODE_REVIEW_CREDENTIAL_FILE"
    chmod 600 "$ENCODE_REVIEW_CREDENTIAL_FILE"
    install -d -o root -g root -m 0755 "$ENCODE_REVIEW_DROPIN_DIR"
    printf '[Service]\nLoadCredential=production-upload:%s\n' "$ENCODE_REVIEW_CREDENTIAL_FILE" \
      > "$ENCODE_REVIEW_CREDENTIAL_DROPIN"
    chmod 0644 "$ENCODE_REVIEW_CREDENTIAL_DROPIN"
    own_file "$ENCODE_REVIEW_CREDENTIAL_DROPIN"
  else
    rm -f "$ENCODE_REVIEW_CREDENTIAL_DROPIN"
  fi
  encode_review_apply_worker

  # The must-use plugin, in each site checkout's ignored mu-plugins/*/ folder.
  # Like the rest of a checkout it belongs to the deploy user; PHP-FPM only reads it.
  for site in "${ENCODE_REVIEW_PLUGIN_SITES[@]}"; do
    docroot="${site}/web/app/mu-plugins"
    if [[ ! -d "$docroot" ]]; then
      printf 'warning: encode review plugin not installed: %s is missing\n' "$docroot" >&2
      continue
    fi
    plugin_target="${site}/${ENCODE_REVIEW_PLUGIN_SUBDIR}"
    install -d -o ubuntu -g ubuntu -m 0755 "$plugin_target"
    rsync -a --delete --chown=ubuntu:ubuntu --chmod=D0755,F0644 \
      "${AMAZON_SERVER_ROOT}/encode-review/wp-plugin/encode-review/" "${plugin_target}/"
  done

  # Running PHP-FPM workers keep the groups they started with.
  if [[ "$group_changed" == true ]]; then
    local unit
    for unit in $(for site in ampas guilds; do php_fpm_unit "$(php_site_version "$site")"; printf '\n'; done | sort -u); do
      systemctl reload "$unit"
    done
  fi
}
