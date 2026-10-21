#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  printf 'cloud-init.sh must run as root\n' >&2
  exit 1
fi

# Provisioner-owned files outside the rsynced nginx tree and the templates
# directory, recorded where each is written. A successful run hashes them into
# the applied manifest (write_applied_state).
OWNED_FILES=()
own_file() {
  OWNED_FILES+=("$@")
}

# The installed command is the converge shim from this checkout, reinstalled
# on every run so it tracks the repo. The old provisioner name is a symlink.
CONVERGE_COMMAND='/usr/local/sbin/amazon-server-converge'
PROVISIONER_SCRIPT='/usr/local/sbin/amazon-staging-provision'
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
install -o root -g root -m 0755 "$(dirname "$SCRIPT_SOURCE")/converge.sh" "$CONVERGE_COMMAND"
ln -sfn "$CONVERGE_COMMAND" "$PROVISIONER_SCRIPT"
own_file "$CONVERGE_COMMAND"

# PHP version for each site's FPM pool, and the version /usr/bin/php runs.
# Moving a site between versions is one value here and a converge. Every PHP
# socket, pool directory, package, apt pin and unit derives from these
# (infra/php-sites.sh); rolling back is setting the old value again.
# shellcheck disable=SC2034  # read by infra/php-sites.sh, sourced below
declare \
  RSVP_PHP_VERSION='8.4' \
  AMPAS_PHP_VERSION='8.4' \
  GUILDS_PHP_VERSION='8.4' \
  PHP_CLI_VERSION='7.4'
# shellcheck source=infra/php-sites.sh
source "$(dirname "$SCRIPT_SOURCE")/php-sites.sh"

# ENV-DELTAS.md: Site and environment values / staging. These are the only
# environment-specific values rendered into the installed serving tree.
STAGING_RSVP_SERVER_NAME='stg.rsvp.amazonmgmstudiosawards.com'
STAGING_RSVP_HTTP_CI_ENV='staging'
STAGING_RSVP_DOCROOT='/var/www/html/rsvp'
STAGING_RSVP_PUBLIC_DOCROOT='/var/www/html/rsvp/public'
STAGING_RSVP_EMBED_DOCROOT='/var/www/html/rsvp/public/consideramazon/'
STAGING_RSVP_FPM_SOCKET="$(php_site_socket rsvp)"
STAGING_RSVP_LOG_ROOT='/var/log/nginx/rsvp'
STAGING_RSVP_AUTH_REALM='Staging'
STAGING_RSVP_AUTH_FILE='/etc/nginx/.htpasswd'

# ENV-DELTAS.md: AMPAS and Guilds staging server names, docroots, pools, and
# log roots. The WordPress source trees are provisioner-owned after apply.
STAGING_AMPAS_SERVER_NAME='stg.amazonmgmstudiosawards.com'
STAGING_AMPAS_DOCROOT='/var/www/html/amazon-studios-ampas/web'
STAGING_AMPAS_FPM_SOCKET="$(php_site_socket ampas)"
STAGING_AMPAS_LOG_ROOT='/var/log/nginx/ampas'
STAGING_GUILDS_SERVER_NAME='stg.amazonmgmstudiosguilds.com'
STAGING_GUILDS_DOCROOT='/var/www/html/amazon-studios-guilds/web'
STAGING_GUILDS_FPM_SOCKET="$(php_site_socket guilds)"
STAGING_GUILDS_LOG_ROOT='/var/log/nginx/guilds'

# ENV-DELTAS.md: Site-specific shared-policy values and RSVP's staging embed
# routing/cache values. The legacy /rsvp/ rule stays no-cache; the generic
# RSVP CSS/JS rule uses the deployed staging values.
STAGING_RSVP_FRAME_OPTIONS=''
STAGING_RSVP_ASSET_EXPIRES='1h'
STAGING_RSVP_ASSET_CACHE_CONTROL='public, must-revalidate'
STAGING_RSVP_CSS_EXPIRES='1h'
STAGING_RSVP_CSS_CACHE_CONTROL='public, must-revalidate'
STAGING_RSVP_CSS_PRAGMA=''
STAGING_RSVP_LEGACY_CSS_EXPIRES='-1'
STAGING_RSVP_LEGACY_CSS_CACHE_CONTROL='no-store, no-cache, must-revalidate'
STAGING_RSVP_LEGACY_CSS_PRAGMA=''
STAGING_RSVP_EMBED_CORS_ORIGIN='*'
STAGING_RSVP_EMBED_CORS_METHODS='GET, OPTIONS'
STAGING_RSVP_EMBED_CORS_HEADERS='Content-Type'
STAGING_RSVP_EMBED_CACHE_EXPIRES='-1'
STAGING_RSVP_EMBED_CACHE_CONTROL='no-store, no-cache, must-revalidate'

STAGING_AMPAS_FRAME_OPTIONS=''
STAGING_AMPAS_ASSET_EXPIRES='1y'
STAGING_AMPAS_ASSET_CACHE_CONTROL=''
STAGING_AMPAS_CSS_EXPIRES='-1'
STAGING_AMPAS_CSS_CACHE_CONTROL='no-store, no-cache, must-revalidate'
STAGING_AMPAS_CSS_PRAGMA='no-cache'
STAGING_GUILDS_FRAME_OPTIONS='SAMEORIGIN'
STAGING_GUILDS_ASSET_EXPIRES='1y'
STAGING_GUILDS_ASSET_CACHE_CONTROL=''
STAGING_GUILDS_CSS_EXPIRES='1y'
STAGING_GUILDS_CSS_CACHE_CONTROL=''
STAGING_GUILDS_CSS_PRAGMA=''

# ENV-DELTAS.md: provisioner-owned TLS paths and CSP include. DNS and certificate
# issuance remain manual steps in infra/README.md; the CSP comes from infra/csp/.
STAGING_RSVP_TLS_CERT='/etc/letsencrypt/live/stg.rsvp.amazonmgmstudiosawards.com/fullchain.pem'
STAGING_RSVP_TLS_KEY='/etc/letsencrypt/live/stg.rsvp.amazonmgmstudiosawards.com/privkey.pem'
STAGING_AMPAS_TLS_CERT='/etc/letsencrypt/live/stg.amazonmgmstudiosawards.com/fullchain.pem'
STAGING_AMPAS_TLS_KEY='/etc/letsencrypt/live/stg.amazonmgmstudiosawards.com/privkey.pem'
STAGING_GUILDS_TLS_CERT='/etc/letsencrypt/live/stg.amazonmgmstudiosguilds.com/fullchain.pem'
STAGING_GUILDS_TLS_KEY='/etc/letsencrypt/live/stg.amazonmgmstudiosguilds.com/privkey.pem'
STAGING_ACME_DOCROOT='/var/www/html/.well-known'
STAGING_CSP_INCLUDE='/etc/nginx/snippets/rsvp-staging-csp.conf'

# ENV-DELTAS.md: Managed database connection rows. The endpoints, names,
# users, and passwords remain provisioner-owned in this root-only file; this
# packet does not create, alter, or import any database.
STAGING_DB_ENV_FILE='/root/amazon-staging/db.env'

# ENV-DELTAS.md: Site and environment values / production. The Terraform
# bootstrap records the environment in /etc/amazon-server.env; provisioner
# re-runs follow it, and an absent marker keeps the staging defaults above
# (existing staging instances predate the marker). The STAGING_ variable
# prefix is the template contract's historical name; only the values below
# differ between environments. The CSP snippet path and db.env handoff path
# are environment-invariant.
AMAZON_SERVER_ENVIRONMENT="$(cat /etc/amazon-server.env 2>/dev/null || echo staging)"

# nginx site error_log level and rotation. Staging keeps debug for
# diagnosis and trims aggressively; production logs warn and keeps two
# weeks (production filled its disk with debug logs, 2026-09-10).
SITE_ERROR_LOG_LEVEL='debug'
SITE_LOG_ROTATE_KEEP='3'
SITE_LOG_ROTATE_MAXSIZE='1G'
if [[ "$AMAZON_SERVER_ENVIRONMENT" == 'production' ]]; then
  SITE_ERROR_LOG_LEVEL='warn'
  SITE_LOG_ROTATE_KEEP='14'
  SITE_LOG_ROTATE_MAXSIZE='4G'
  STAGING_RSVP_SERVER_NAME='rsvp.amazonmgmstudiosawards.com'
  STAGING_RSVP_HTTP_CI_ENV='production'

  # ENV-DELTAS.md: the production embed ships no .htpasswd gate. An empty
  # realm leaves the $rsvp_auth map default at "off".
  STAGING_RSVP_AUTH_REALM=''

  STAGING_AMPAS_SERVER_NAME='amazonmgmstudiosawards.com www.amazonmgmstudiosawards.com'

  # ENV-DELTAS.md records no deployed production Guilds host binding (the
  # deployed reference is a coming-soon placeholder block). DRIVER RATIFY
  # before any CDN origin flip.
  STAGING_GUILDS_SERVER_NAME='amazonmgmstudiosguilds.com www.amazonmgmstudiosguilds.com'

  STAGING_RSVP_TLS_CERT='/etc/letsencrypt/live/rsvp.amazonmgmstudiosawards.com/fullchain.pem'
  STAGING_RSVP_TLS_KEY='/etc/letsencrypt/live/rsvp.amazonmgmstudiosawards.com/privkey.pem'
  STAGING_AMPAS_TLS_CERT='/etc/letsencrypt/live/amazonmgmstudiosawards.com/fullchain.pem'
  STAGING_AMPAS_TLS_KEY='/etc/letsencrypt/live/amazonmgmstudiosawards.com/privkey.pem'
  STAGING_GUILDS_TLS_CERT='/etc/letsencrypt/live/amazonmgmstudiosguilds.com/fullchain.pem'
  STAGING_GUILDS_TLS_KEY='/etc/letsencrypt/live/amazonmgmstudiosguilds.com/privkey.pem'
fi

# The packet provisions the serving tree only. Site releases are placed in the
# docroots by the driver after apply, and existing managed databases stay out
# of this instance module.
AMAZON_SERVER_REPO_URL='https://github.com/abendy/amazon-server.git'
# The Terraform bootstrap records its branch in /etc/amazon-server.ref;
# re-runs follow the same branch. Fresh-from-develop remains the default.
AMAZON_SERVER_REF="$(cat /etc/amazon-server.ref 2>/dev/null || echo develop)"
AMAZON_SERVER_ROOT='/opt/amazon-server'
NGINX_ROOT='/etc/nginx'
NGINX_USER='www-data'
PHP_FPM_LOG_ROOT='/var/log/php-fpm'
TEMPLATE_ROOT='/var/lib/amazon-staging/templates'

STAGING_RSVP_ACCESS_LOG="${STAGING_RSVP_LOG_ROOT}/access.log"
STAGING_RSVP_SCRIPTS_LOG="${STAGING_RSVP_LOG_ROOT}/scripts.log"
STAGING_RSVP_ERROR_LOG="${STAGING_RSVP_LOG_ROOT}/error.log"
STAGING_RSVP_EMBED_ACCESS_LOG="${STAGING_RSVP_LOG_ROOT}/embed-access.log"
STAGING_AMPAS_ACCESS_LOG="${STAGING_AMPAS_LOG_ROOT}/access.log"
STAGING_AMPAS_SCRIPTS_LOG="${STAGING_AMPAS_LOG_ROOT}/scripts.log"
STAGING_AMPAS_ERROR_LOG="${STAGING_AMPAS_LOG_ROOT}/error.log"
STAGING_GUILDS_ACCESS_LOG="${STAGING_GUILDS_LOG_ROOT}/access.log"
STAGING_GUILDS_SCRIPTS_LOG="${STAGING_GUILDS_LOG_ROOT}/scripts.log"
STAGING_GUILDS_ERROR_LOG="${STAGING_GUILDS_LOG_ROOT}/error.log"

export STAGING_RSVP_SERVER_NAME STAGING_RSVP_HTTP_CI_ENV STAGING_RSVP_DOCROOT
export STAGING_RSVP_PUBLIC_DOCROOT
export STAGING_RSVP_EMBED_DOCROOT STAGING_RSVP_FPM_SOCKET STAGING_RSVP_AUTH_FILE
export STAGING_RSVP_ACCESS_LOG STAGING_RSVP_SCRIPTS_LOG STAGING_RSVP_ERROR_LOG
export STAGING_RSVP_EMBED_ACCESS_LOG STAGING_RSVP_FRAME_OPTIONS
export STAGING_RSVP_ASSET_EXPIRES STAGING_RSVP_ASSET_CACHE_CONTROL
export STAGING_RSVP_CSS_EXPIRES STAGING_RSVP_CSS_CACHE_CONTROL STAGING_RSVP_CSS_PRAGMA
export STAGING_RSVP_LEGACY_CSS_EXPIRES STAGING_RSVP_LEGACY_CSS_CACHE_CONTROL
export STAGING_RSVP_LEGACY_CSS_PRAGMA STAGING_RSVP_EMBED_CORS_ORIGIN
export STAGING_RSVP_EMBED_CORS_METHODS STAGING_RSVP_EMBED_CORS_HEADERS
export STAGING_RSVP_EMBED_CACHE_EXPIRES STAGING_RSVP_EMBED_CACHE_CONTROL
export STAGING_RSVP_TLS_CERT STAGING_RSVP_TLS_KEY STAGING_ACME_DOCROOT
export STAGING_CSP_INCLUDE STAGING_AMPAS_SERVER_NAME STAGING_AMPAS_DOCROOT
export STAGING_AMPAS_FPM_SOCKET STAGING_AMPAS_ACCESS_LOG STAGING_AMPAS_SCRIPTS_LOG
export STAGING_AMPAS_ERROR_LOG STAGING_AMPAS_FRAME_OPTIONS STAGING_AMPAS_ASSET_EXPIRES
export STAGING_AMPAS_ASSET_CACHE_CONTROL STAGING_AMPAS_CSS_EXPIRES
export STAGING_AMPAS_CSS_CACHE_CONTROL STAGING_AMPAS_CSS_PRAGMA STAGING_AMPAS_TLS_CERT
export STAGING_AMPAS_TLS_KEY STAGING_GUILDS_SERVER_NAME STAGING_GUILDS_DOCROOT
export STAGING_GUILDS_FPM_SOCKET STAGING_GUILDS_ACCESS_LOG
export STAGING_GUILDS_SCRIPTS_LOG STAGING_GUILDS_ERROR_LOG STAGING_GUILDS_FRAME_OPTIONS
export STAGING_GUILDS_ASSET_EXPIRES STAGING_GUILDS_ASSET_CACHE_CONTROL
export STAGING_GUILDS_CSS_EXPIRES STAGING_GUILDS_CSS_CACHE_CONTROL
export STAGING_GUILDS_CSS_PRAGMA STAGING_GUILDS_TLS_CERT STAGING_GUILDS_TLS_KEY
export SITE_ERROR_LOG_LEVEL

STAGING_TEMPLATE_VARS="\${STAGING_RSVP_SERVER_NAME} \${STAGING_RSVP_HTTP_CI_ENV} \${STAGING_RSVP_DOCROOT} \${STAGING_RSVP_PUBLIC_DOCROOT} \${STAGING_RSVP_EMBED_DOCROOT} \${STAGING_RSVP_FPM_SOCKET} \${STAGING_RSVP_AUTH_FILE} \${STAGING_RSVP_ACCESS_LOG} \${STAGING_RSVP_SCRIPTS_LOG} \${STAGING_RSVP_ERROR_LOG} \${STAGING_RSVP_EMBED_ACCESS_LOG} \${STAGING_RSVP_FRAME_OPTIONS} \${STAGING_RSVP_ASSET_EXPIRES} \${STAGING_RSVP_ASSET_CACHE_CONTROL} \${STAGING_RSVP_CSS_EXPIRES} \${STAGING_RSVP_CSS_CACHE_CONTROL} \${STAGING_RSVP_CSS_PRAGMA} \${STAGING_RSVP_LEGACY_CSS_EXPIRES} \${STAGING_RSVP_LEGACY_CSS_CACHE_CONTROL} \${STAGING_RSVP_LEGACY_CSS_PRAGMA} \${STAGING_RSVP_EMBED_CORS_ORIGIN} \${STAGING_RSVP_EMBED_CORS_METHODS} \${STAGING_RSVP_EMBED_CORS_HEADERS} \${STAGING_RSVP_EMBED_CACHE_EXPIRES} \${STAGING_RSVP_EMBED_CACHE_CONTROL} \${STAGING_RSVP_TLS_CERT} \${STAGING_RSVP_TLS_KEY} \${STAGING_ACME_DOCROOT} \${STAGING_CSP_INCLUDE}"
SITE_TEMPLATE_VARS="\${SITE_SERVER_NAME} \${SITE_DOCROOT} \${SITE_FPM_SOCKET} \${SITE_ACCESS_LOG} \${SITE_SCRIPTS_LOG} \${SITE_ERROR_LOG} \${SITE_ERROR_LOG_LEVEL} \${SITE_FRAME_OPTIONS} \${SITE_ASSET_EXPIRES} \${SITE_ASSET_CACHE_CONTROL} \${SITE_CSS_EXPIRES} \${SITE_CSS_CACHE_CONTROL} \${SITE_CSS_PRAGMA} \${SITE_TLS_CERT} \${SITE_TLS_KEY}"

export DEBIAN_FRONTEND='noninteractive'
export PATH='/usr/sbin:/usr/bin:/sbin:/bin'

apt-get update
apt-get install -y \
  apache2-utils \
  ca-certificates \
  certbot \
  curl \
  gettext-base \
  git \
  gnupg \
  nginx \
  python3-certbot-nginx \
  rsync \
  software-properties-common \
  unzip

add-apt-repository -y ppa:ondrej/php

php_write_apt_pins

apt-get update
php_install_packages
php_write_timezone_ini
php_write_security_ini

# Composer comes from the phar installer, never apt: the Ubuntu composer
# package depends on the distribution PHP and would install it beside the
# configured versions.
# cloud-init's script runner provides no HOME, and the installer refuses to
# run without one (first-boot finding, abendy/amazon-docs#85).
if ! command -v composer >/dev/null 2>&1; then
  HOME="${HOME:-/root}" curl -sS https://getcomposer.org/installer | HOME="${HOME:-/root}" php -- \
    --install-dir=/usr/local/bin --filename=composer --quiet
fi

# Node/npm for on-instance theme builds. Remove once GitHub Actions
# compile and deploy the theme assets.
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

php_enable_units
systemctl enable nginx

install -d -o root -g root -m 0700 "$(dirname "$STAGING_DB_ENV_FILE")"
if [[ -e "$STAGING_DB_ENV_FILE" ]]; then
  chown root:root "$STAGING_DB_ENV_FILE"
  chmod 600 "$STAGING_DB_ENV_FILE"
fi

install -d -o root -g root -m 0755 "$PHP_FPM_LOG_ROOT"

php_place_pools

# Under amazon-server-converge the shim already fetched and checked out the
# ref before starting this script; fetching again here could rewrite the file
# bash is reading.
if [[ -n "${AMAZON_SERVER_CONVERGE_SHA:-}" && -d "$AMAZON_SERVER_ROOT/.git" ]]; then
  printf 'Using the checkout placed by amazon-server-converge (%s)\n' "$AMAZON_SERVER_CONVERGE_SHA"
elif [[ -d "$AMAZON_SERVER_ROOT/.git" ]]; then
  git -C "$AMAZON_SERVER_ROOT" fetch --depth 1 origin "$AMAZON_SERVER_REF"
  git -C "$AMAZON_SERVER_ROOT" checkout --detach FETCH_HEAD
else
  git clone --depth 1 --branch "$AMAZON_SERVER_REF" "$AMAZON_SERVER_REPO_URL" "$AMAZON_SERVER_ROOT"
fi

install -d -o root -g root -m 0755 "$NGINX_ROOT"
rsync -a --delete --exclude='.htpasswd' --exclude='snippets/' \
  "$AMAZON_SERVER_ROOT/nginx/" "$NGINX_ROOT/"
install -d -o root -g root -m 0755 "$NGINX_ROOT/snippets"
# nginx workers read the password file on each login, as ${NGINX_USER}. A
# root-only file turns every login into a 500.
if [[ ! -e "$STAGING_RSVP_AUTH_FILE" ]]; then
  install -o root -g "$NGINX_USER" -m 0640 /dev/null "$STAGING_RSVP_AUTH_FILE"
else
  chown "root:${NGINX_USER}" "$STAGING_RSVP_AUTH_FILE"
  chmod 640 "$STAGING_RSVP_AUTH_FILE"
fi
# The RSVP CSP is provisioner-owned: one policy per environment, installed at
# the snippet path the RSVP server block includes. The rsync above still spares
# snippets/, so the package's own snippets stay as they are.
install -o root -g root -m 0644 \
  "$AMAZON_SERVER_ROOT/infra/csp/${AMAZON_SERVER_ENVIRONMENT}.conf" "$STAGING_CSP_INCLUDE"
own_file "$STAGING_CSP_INCLUDE"

for docroot in \
  "$STAGING_RSVP_DOCROOT" \
  "$STAGING_RSVP_PUBLIC_DOCROOT" \
  "$STAGING_RSVP_EMBED_DOCROOT" \
  "$STAGING_AMPAS_DOCROOT" \
  "$STAGING_GUILDS_DOCROOT" \
  "$STAGING_ACME_DOCROOT"; do
  install -d -o www-data -g www-data -m 0755 "$docroot"
done

for log_root in \
  "$STAGING_RSVP_LOG_ROOT" \
  "$STAGING_AMPAS_LOG_ROOT" \
  "$STAGING_GUILDS_LOG_ROOT"; do
  install -d -o www-data -g www-data -m 0755 "$log_root"
done

render_base_config() {
  sed -i "s/^user nginx;$/user ${NGINX_USER};/" "$NGINX_ROOT/nginx.conf"

  # An empty realm (production) keeps the $rsvp_auth map default at "off" —
  # no .htpasswd gate on the embed.
  if [[ -z "$STAGING_RSVP_AUTH_REALM" ]]; then
    return
  fi

  local rendered_config
  rendered_config="$(mktemp)"
  awk -v auth_realm="$STAGING_RSVP_AUTH_REALM" '
    /map \$http_origin \$rsvp_auth/ { in_auth_map = 1 }
    in_auth_map && /default off;/ {
      printf "    default \"%s\";\n", auth_realm
      in_auth_map = 0
      next
    }
    { print }
  ' "$NGINX_ROOT/nginx.conf" > "$rendered_config"
  install -o root -g root -m 0644 "$rendered_config" "$NGINX_ROOT/nginx.conf"
  rm -f "$rendered_config"
}

# The per-site log directories sit outside the stock nginx logrotate glob
# (/var/log/nginx/*.log); without this rule they grow until the disk fills
# (production, 2026-09-10: 65G of error logs in nine days). maxsize lets a
# debug-level staging log rotate before its daily slot when it spikes.
write_logrotate() {
  cat > /etc/logrotate.d/nginx-sites <<LOGROTATE
/var/log/nginx/*/*.log {
	daily
	maxsize ${SITE_LOG_ROTATE_MAXSIZE}
	missingok
	rotate ${SITE_LOG_ROTATE_KEEP}
	compress
	delaycompress
	notifempty
	create 0640 www-data adm
	sharedscripts
	postrotate
		invoke-rc.d nginx rotate >/dev/null 2>&1
	endscript
}
LOGROTATE
  chmod 0644 /etc/logrotate.d/nginx-sites
  own_file /etc/logrotate.d/nginx-sites
}

render_rsvp_static_include() {
  local rsvp_static_include="$NGINX_ROOT/includes/rsvp-static.conf"

  awk '/^# W3 Total Cache rules retained/{exit} {print}' \
    "$NGINX_ROOT/includes/static.conf" > "$rsvp_static_include"
  local css_cache_control="\\\$site_css_cache_control"
  local legacy_css_cache_control="\$site_legacy_css_cache_control"
  local css_expires="\\\$site_css_expires"
  local legacy_css_expires="\$site_legacy_css_expires"
  local css_pragma="\\\$site_css_pragma"
  local legacy_css_pragma="\$site_legacy_css_pragma"
  sed -i "0,/add_header Cache-Control ${css_cache_control} always;/s//add_header Cache-Control ${legacy_css_cache_control} always;/" \
    "$rsvp_static_include"
  sed -i "0,/expires ${css_expires};/s//expires ${legacy_css_expires};/" \
    "$rsvp_static_include"
  sed -i "0,/add_header Pragma ${css_pragma} always;/s//add_header Pragma ${legacy_css_pragma} always;/" \
    "$rsvp_static_include"
  sed -i '/css/s#\^/(?!admin/)#\^/#' "$rsvp_static_include"
  chown root:root "$rsvp_static_include"
  chmod 0644 "$rsvp_static_include"
}

write_templates() {
  install -d -o root -g root -m 0755 "$TEMPLATE_ROOT"

  cat > "$TEMPLATE_ROOT/rsvp-http.conf.tpl" <<'NGINX'
upstream rsvp_fpm {
  server unix:${STAGING_RSVP_FPM_SOCKET};
}

server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name ${STAGING_RSVP_SERVER_NAME};

  root ${STAGING_RSVP_DOCROOT};
  index index.php;
  rewrite_log on;

  set $site_frame_options "${STAGING_RSVP_FRAME_OPTIONS}";
  set $site_asset_expires ${STAGING_RSVP_ASSET_EXPIRES};
  set $site_asset_cache_control "${STAGING_RSVP_ASSET_CACHE_CONTROL}";
  set $site_css_expires ${STAGING_RSVP_CSS_EXPIRES};
  set $site_css_cache_control "${STAGING_RSVP_CSS_CACHE_CONTROL}";
  set $site_css_pragma "${STAGING_RSVP_CSS_PRAGMA}";
  set $site_legacy_css_expires ${STAGING_RSVP_LEGACY_CSS_EXPIRES};
  set $site_legacy_css_cache_control "${STAGING_RSVP_LEGACY_CSS_CACHE_CONTROL}";
  set $site_legacy_css_pragma "${STAGING_RSVP_LEGACY_CSS_PRAGMA}";
  set $rsvp_http_ci_env ${STAGING_RSVP_HTTP_CI_ENV};

  access_log ${STAGING_RSVP_ACCESS_LOG} main;
  access_log ${STAGING_RSVP_SCRIPTS_LOG} scripts;
  error_log ${STAGING_RSVP_ERROR_LOG} warn;

  add_header Access-Control-Allow-Origin $rsvp_cors_origin always;
  add_header Access-Control-Allow-Methods $rsvp_cors_methods always;
  add_header Access-Control-Allow-Headers $rsvp_cors_headers always;

  if ($host ~* ^www\.(?<rsvp_bare_host>.+)$) {
    return 301 https://$rsvp_bare_host$request_uri;
  }

  include snippets/rsvp-staging-csp.conf;
  include includes/security.conf;
  include includes/rsvp-static.conf;

  location ^~ /.well-known/acme-challenge/ {
    root ${STAGING_ACME_DOCROOT};
  }

  location = /rsvp/consideramazon {
    add_header Access-Control-Allow-Origin "${STAGING_RSVP_EMBED_CORS_ORIGIN}" always;
    add_header Access-Control-Allow-Methods "${STAGING_RSVP_EMBED_CORS_METHODS}" always;
    add_header Access-Control-Allow-Headers "${STAGING_RSVP_EMBED_CORS_HEADERS}" always;
    return 301 $scheme://$http_host/rsvp/consideramazon/;
  }

  location ^~ /rsvp/consideramazon/ {
    alias ${STAGING_RSVP_EMBED_DOCROOT};
    index index.html;

    access_log ${STAGING_RSVP_EMBED_ACCESS_LOG} combined;

    add_header Access-Control-Allow-Origin "${STAGING_RSVP_EMBED_CORS_ORIGIN}" always;
    add_header Access-Control-Allow-Methods "${STAGING_RSVP_EMBED_CORS_METHODS}" always;
    add_header Access-Control-Allow-Headers "${STAGING_RSVP_EMBED_CORS_HEADERS}" always;
    add_header Cache-Control "${STAGING_RSVP_EMBED_CACHE_CONTROL}" always;
    expires ${STAGING_RSVP_EMBED_CACHE_EXPIRES};
    auth_basic $rsvp_auth;
    auth_basic_user_file ${STAGING_RSVP_AUTH_FILE};

    if ($request_method = OPTIONS) {
      return 204;
    }
  }

  location = /admin {
    return 301 /admin/;
  }

  location /admin/ {
    try_files $uri $uri/ /admin/index.php?$query_string;
  }

  location ~ \.php$ {
    try_files $uri =404;

    fastcgi_split_path_info ^(.+\.php)(/.+)$;
    fastcgi_pass rsvp_fpm;
    fastcgi_index index.php;

    include includes/fastcgi.conf;
    fastcgi_param PATH_INFO $fastcgi_path_info;
    fastcgi_param HTTP_CI_ENV $rsvp_http_ci_env;

    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
    fastcgi_read_timeout 300;
  }

  location / {
    root ${STAGING_RSVP_PUBLIC_DOCROOT};
    try_files $uri $uri/ =404;
  }
}
NGINX

  cat > "$TEMPLATE_ROOT/rsvp-https.conf.tpl" <<'NGINX'
upstream rsvp_fpm {
  server unix:${STAGING_RSVP_FPM_SOCKET};
}

server {
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name ${STAGING_RSVP_SERVER_NAME};

  ssl_certificate ${STAGING_RSVP_TLS_CERT};
  ssl_certificate_key ${STAGING_RSVP_TLS_KEY};

  root ${STAGING_RSVP_DOCROOT};
  index index.php;
  rewrite_log on;

  set $site_frame_options "${STAGING_RSVP_FRAME_OPTIONS}";
  set $site_asset_expires ${STAGING_RSVP_ASSET_EXPIRES};
  set $site_asset_cache_control "${STAGING_RSVP_ASSET_CACHE_CONTROL}";
  set $site_css_expires ${STAGING_RSVP_CSS_EXPIRES};
  set $site_css_cache_control "${STAGING_RSVP_CSS_CACHE_CONTROL}";
  set $site_css_pragma "${STAGING_RSVP_CSS_PRAGMA}";
  set $site_legacy_css_expires ${STAGING_RSVP_LEGACY_CSS_EXPIRES};
  set $site_legacy_css_cache_control "${STAGING_RSVP_LEGACY_CSS_CACHE_CONTROL}";
  set $site_legacy_css_pragma "${STAGING_RSVP_LEGACY_CSS_PRAGMA}";
  set $rsvp_http_ci_env ${STAGING_RSVP_HTTP_CI_ENV};

  access_log ${STAGING_RSVP_ACCESS_LOG} main;
  access_log ${STAGING_RSVP_SCRIPTS_LOG} scripts;
  error_log ${STAGING_RSVP_ERROR_LOG} warn;

  add_header Access-Control-Allow-Origin $rsvp_cors_origin always;
  add_header Access-Control-Allow-Methods $rsvp_cors_methods always;
  add_header Access-Control-Allow-Headers $rsvp_cors_headers always;

  if ($host ~* ^www\.(?<rsvp_bare_host>.+)$) {
    return 301 https://$rsvp_bare_host$request_uri;
  }

  include snippets/rsvp-staging-csp.conf;
  include includes/security.conf;
  include includes/rsvp-static.conf;

  location = /rsvp/consideramazon {
    add_header Access-Control-Allow-Origin "${STAGING_RSVP_EMBED_CORS_ORIGIN}" always;
    add_header Access-Control-Allow-Methods "${STAGING_RSVP_EMBED_CORS_METHODS}" always;
    add_header Access-Control-Allow-Headers "${STAGING_RSVP_EMBED_CORS_HEADERS}" always;
    return 301 $scheme://$http_host/rsvp/consideramazon/;
  }

  location ^~ /rsvp/consideramazon/ {
    alias ${STAGING_RSVP_EMBED_DOCROOT};
    index index.html;

    access_log ${STAGING_RSVP_EMBED_ACCESS_LOG} combined;

    add_header Access-Control-Allow-Origin "${STAGING_RSVP_EMBED_CORS_ORIGIN}" always;
    add_header Access-Control-Allow-Methods "${STAGING_RSVP_EMBED_CORS_METHODS}" always;
    add_header Access-Control-Allow-Headers "${STAGING_RSVP_EMBED_CORS_HEADERS}" always;
    add_header Cache-Control "${STAGING_RSVP_EMBED_CACHE_CONTROL}" always;
    expires ${STAGING_RSVP_EMBED_CACHE_EXPIRES};
    auth_basic $rsvp_auth;
    auth_basic_user_file ${STAGING_RSVP_AUTH_FILE};

    if ($request_method = OPTIONS) {
      return 204;
    }
  }

  location = /admin {
    return 301 /admin/;
  }

  location /admin/ {
    try_files $uri $uri/ /admin/index.php?$query_string;
  }

  location ~ \.php$ {
    try_files $uri =404;

    fastcgi_split_path_info ^(.+\.php)(/.+)$;
    fastcgi_pass rsvp_fpm;
    fastcgi_index index.php;

    include includes/fastcgi.conf;
    fastcgi_param PATH_INFO $fastcgi_path_info;
    fastcgi_param HTTP_CI_ENV $rsvp_http_ci_env;

    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
    fastcgi_read_timeout 300;
  }

  location / {
    root ${STAGING_RSVP_PUBLIC_DOCROOT};
    try_files $uri $uri/ =404;
  }
}
NGINX

  cat > "$TEMPLATE_ROOT/rsvp-redirect.conf.tpl" <<'NGINX'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name ${STAGING_RSVP_SERVER_NAME};

  access_log ${STAGING_RSVP_ACCESS_LOG} main;
  error_log ${STAGING_RSVP_ERROR_LOG} warn;

  location ^~ /.well-known/acme-challenge/ {
    root ${STAGING_ACME_DOCROOT};
  }

  location / {
    return 301 https://$host$request_uri;
  }
}
NGINX

  cat > "$TEMPLATE_ROOT/wp-http.conf.tpl" <<'NGINX'
server {
  listen 80;
  listen [::]:80;
  server_name ${SITE_SERVER_NAME};

  root ${SITE_DOCROOT};
  index index.php;
  rewrite_log on;

  set $wordpress_fpm unix:${SITE_FPM_SOCKET};
  set $site_frame_options "${SITE_FRAME_OPTIONS}";
  set $site_asset_expires ${SITE_ASSET_EXPIRES};
  set $site_asset_cache_control "${SITE_ASSET_CACHE_CONTROL}";
  set $site_css_expires ${SITE_CSS_EXPIRES};
  set $site_css_cache_control "${SITE_CSS_CACHE_CONTROL}";
  set $site_css_pragma "${SITE_CSS_PRAGMA}";

  access_log ${SITE_ACCESS_LOG} main;
  access_log ${SITE_SCRIPTS_LOG} scripts;
  error_log ${SITE_ERROR_LOG} ${SITE_ERROR_LOG_LEVEL};

  include includes/security.conf;
  include includes/static.conf;
  include includes/wordpress.conf;
}
NGINX

  cat > "$TEMPLATE_ROOT/wp-https.conf.tpl" <<'NGINX'
server {
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name ${SITE_SERVER_NAME};

  ssl_certificate ${SITE_TLS_CERT};
  ssl_certificate_key ${SITE_TLS_KEY};

  root ${SITE_DOCROOT};
  index index.php;
  rewrite_log on;

  set $wordpress_fpm unix:${SITE_FPM_SOCKET};
  set $site_frame_options "${SITE_FRAME_OPTIONS}";
  set $site_asset_expires ${SITE_ASSET_EXPIRES};
  set $site_asset_cache_control "${SITE_ASSET_CACHE_CONTROL}";
  set $site_css_expires ${SITE_CSS_EXPIRES};
  set $site_css_cache_control "${SITE_CSS_CACHE_CONTROL}";
  set $site_css_pragma "${SITE_CSS_PRAGMA}";

  access_log ${SITE_ACCESS_LOG} main;
  access_log ${SITE_SCRIPTS_LOG} scripts;
  error_log ${SITE_ERROR_LOG} ${SITE_ERROR_LOG_LEVEL};

  include includes/security.conf;
  include includes/static.conf;
  include includes/wordpress.conf;
}
NGINX

  cat > "$TEMPLATE_ROOT/wp-redirect.conf.tpl" <<'NGINX'
server {
  listen 80;
  listen [::]:80;
  server_name ${SITE_SERVER_NAME};

  access_log ${SITE_ACCESS_LOG} main;
  error_log ${SITE_ERROR_LOG} ${SITE_ERROR_LOG_LEVEL};

  location / {
    return 301 https://$host$request_uri;
  }
}
NGINX
}

render_staging_template() {
  local template_file="$1"
  local output_file="$2"
  envsubst "$STAGING_TEMPLATE_VARS" < "$template_file" > "$output_file"
}

render_site_template() {
  local template_file="$1"
  local output_file="$2"
  envsubst "$SITE_TEMPLATE_VARS" < "$template_file" > "$output_file"
}

render_rsvp_server() {
  local rendered_file="$NGINX_ROOT/server_blocks/rsvp.conf"
  local http_file
  local https_file
  local redirect_file

  http_file="$(mktemp)"
  https_file="$(mktemp)"
  redirect_file="$(mktemp)"

  if [[ "$STAGING_TLS_READY" == true ]]; then
    render_staging_template "$TEMPLATE_ROOT/rsvp-redirect.conf.tpl" "$redirect_file"
    render_staging_template "$TEMPLATE_ROOT/rsvp-https.conf.tpl" "$https_file"
    cat "$redirect_file" "$https_file" > "$rendered_file"
  else
    render_staging_template "$TEMPLATE_ROOT/rsvp-http.conf.tpl" "$http_file"
    install -o root -g root -m 0644 "$http_file" "$rendered_file"
  fi

  rm -f "$http_file" "$https_file" "$redirect_file"
}

render_wordpress_server() {
  local site_server_name="$1"
  local site_docroot="$2"
  local site_fpm_socket="$3"
  local site_access_log="$4"
  local site_scripts_log="$5"
  local site_error_log="$6"
  local site_frame_options="$7"
  local site_asset_expires="$8"
  local site_asset_cache_control="$9"
  local site_css_expires="${10}"
  local site_css_cache_control="${11}"
  local site_css_pragma="${12}"
  local site_tls_cert="${13}"
  local site_tls_key="${14}"
  local rendered_file="${NGINX_ROOT}/server_blocks/${15}.conf"
  local http_file
  local https_file
  local redirect_file

  SITE_SERVER_NAME="$site_server_name"
  SITE_DOCROOT="$site_docroot"
  SITE_FPM_SOCKET="$site_fpm_socket"
  SITE_ACCESS_LOG="$site_access_log"
  SITE_SCRIPTS_LOG="$site_scripts_log"
  SITE_ERROR_LOG="$site_error_log"
  SITE_FRAME_OPTIONS="$site_frame_options"
  SITE_ASSET_EXPIRES="$site_asset_expires"
  SITE_ASSET_CACHE_CONTROL="$site_asset_cache_control"
  SITE_CSS_EXPIRES="$site_css_expires"
  SITE_CSS_CACHE_CONTROL="$site_css_cache_control"
  SITE_CSS_PRAGMA="$site_css_pragma"
  SITE_TLS_CERT="$site_tls_cert"
  SITE_TLS_KEY="$site_tls_key"
  export SITE_SERVER_NAME SITE_DOCROOT SITE_FPM_SOCKET SITE_ACCESS_LOG
  export SITE_SCRIPTS_LOG SITE_ERROR_LOG SITE_FRAME_OPTIONS SITE_ASSET_EXPIRES
  export SITE_ASSET_CACHE_CONTROL SITE_CSS_EXPIRES SITE_CSS_CACHE_CONTROL
  export SITE_CSS_PRAGMA SITE_TLS_CERT SITE_TLS_KEY

  http_file="$(mktemp)"
  https_file="$(mktemp)"
  redirect_file="$(mktemp)"

  if [[ "$STAGING_TLS_READY" == true ]]; then
    render_site_template "$TEMPLATE_ROOT/wp-redirect.conf.tpl" "$redirect_file"
    render_site_template "$TEMPLATE_ROOT/wp-https.conf.tpl" "$https_file"
    cat "$redirect_file" "$https_file" > "$rendered_file"
  else
    render_site_template "$TEMPLATE_ROOT/wp-http.conf.tpl" "$http_file"
    install -o root -g root -m 0644 "$http_file" "$rendered_file"
  fi

  rm -f "$http_file" "$https_file" "$redirect_file"
}

# The hourly RSVP reminder job mails attendees, so it runs on production only,
# and only once the RSVP release with its wrapper is in place: executable and
# free of the old /opt/bitnami paths. Otherwise the run warns and leaves any
# existing file as it is.
install_reminder_cron() {
  local cron_source="$AMAZON_SERVER_ROOT/infra/cron/amazon-rsvp-reminders"
  local cron_file='/etc/cron.d/amazon-rsvp-reminders'
  local wrapper="$STAGING_RSVP_DOCROOT/admin/application/scripts/run_reminder.production.sh"

  if [[ "$AMAZON_SERVER_ENVIRONMENT" != 'production' ]]; then
    printf 'warning: reminder cron not installed: environment is %s, not production\n' \
      "$AMAZON_SERVER_ENVIRONMENT" >&2
  elif [[ ! -x "$wrapper" ]]; then
    printf 'warning: reminder cron not installed: %s is missing or not executable\n' \
      "$wrapper" >&2
  elif grep -qF -- '/opt/bitnami' "$wrapper" || [[ $? -ne 1 ]]; then
    printf 'warning: reminder cron not installed: %s uses /opt/bitnami paths or cannot be read\n' \
      "$wrapper" >&2
  else
    # The wrapper runs PHP_BIN, so the job follows RSVP's configured version.
    local rendered_cron
    rendered_cron="$(mktemp)"
    RSVP_PHP_BIN="/usr/bin/php$(php_site_version rsvp)" \
      envsubst "\${RSVP_PHP_BIN}" < "$cron_source" > "$rendered_cron"
    install -o root -g root -m 0644 "$rendered_cron" "$cron_file"
    rm -f "$rendered_cron"
    own_file "$cron_file"
  fi
}

# Runs only after nginx accepted and reloaded the new config, so a failed run
# leaves the previous marker in place. The manifest covers the rsynced and
# rendered nginx tree (minus the manual .htpasswd and the snippets/ directory
# the rsync spares), the templates, and every own_file path. The marker goes
# last; temp file plus rename keeps each file whole.
write_applied_state() {
  local state_dir='/var/lib/amazon-server'
  local manifest_file="${state_dir}/applied.sha256"
  local applied_file='/etc/amazon-server.applied'
  local manifest_tmp
  local applied_tmp
  local applied_sha

  install -d -o root -g root -m 0755 "$state_dir"
  manifest_tmp="$(mktemp "${manifest_file}.XXXXXX")"
  {
    find "$NGINX_ROOT" -type f ! -path "$STAGING_RSVP_AUTH_FILE" ! -path "$NGINX_ROOT/snippets/*"
    find "$TEMPLATE_ROOT" -type f
    printf '%s\n' "${OWNED_FILES[@]}"
  } | sort -u | xargs -d '\n' sha256sum > "$manifest_tmp"
  chmod 0644 "$manifest_tmp"
  mv -f "$manifest_tmp" "$manifest_file"

  applied_sha="$(git -C "$AMAZON_SERVER_ROOT" rev-parse HEAD)"
  applied_tmp="$(mktemp "${applied_file}.XXXXXX")"
  printf 'sha=%s\nref=%s\nenvironment=%s\napplied_at=%s\n' \
    "$applied_sha" "$AMAZON_SERVER_REF" "$AMAZON_SERVER_ENVIRONMENT" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$applied_tmp"
  chmod 0644 "$applied_tmp"
  mv -f "$applied_tmp" "$applied_file"
  printf 'Applied %s (%s, %s)\n' "$applied_sha" "$AMAZON_SERVER_REF" "$AMAZON_SERVER_ENVIRONMENT"
}

render_base_config
write_logrotate
render_rsvp_static_include
write_templates

STAGING_TLS_READY=false
if [[ -s "$STAGING_RSVP_TLS_CERT" && -s "$STAGING_RSVP_TLS_KEY" \
  && -s "$STAGING_AMPAS_TLS_CERT" && -s "$STAGING_AMPAS_TLS_KEY" \
  && -s "$STAGING_GUILDS_TLS_CERT" && -s "$STAGING_GUILDS_TLS_KEY" ]]; then
  STAGING_TLS_READY=true
fi

render_rsvp_server
render_wordpress_server \
  "$STAGING_AMPAS_SERVER_NAME" \
  "$STAGING_AMPAS_DOCROOT" \
  "$STAGING_AMPAS_FPM_SOCKET" \
  "$STAGING_AMPAS_ACCESS_LOG" \
  "$STAGING_AMPAS_SCRIPTS_LOG" \
  "$STAGING_AMPAS_ERROR_LOG" \
  "$STAGING_AMPAS_FRAME_OPTIONS" \
  "$STAGING_AMPAS_ASSET_EXPIRES" \
  "$STAGING_AMPAS_ASSET_CACHE_CONTROL" \
  "$STAGING_AMPAS_CSS_EXPIRES" \
  "$STAGING_AMPAS_CSS_CACHE_CONTROL" \
  "$STAGING_AMPAS_CSS_PRAGMA" \
  "$STAGING_AMPAS_TLS_CERT" \
  "$STAGING_AMPAS_TLS_KEY" \
  ampas
render_wordpress_server \
  "$STAGING_GUILDS_SERVER_NAME" \
  "$STAGING_GUILDS_DOCROOT" \
  "$STAGING_GUILDS_FPM_SOCKET" \
  "$STAGING_GUILDS_ACCESS_LOG" \
  "$STAGING_GUILDS_SCRIPTS_LOG" \
  "$STAGING_GUILDS_ERROR_LOG" \
  "$STAGING_GUILDS_FRAME_OPTIONS" \
  "$STAGING_GUILDS_ASSET_EXPIRES" \
  "$STAGING_GUILDS_ASSET_CACHE_CONTROL" \
  "$STAGING_GUILDS_CSS_EXPIRES" \
  "$STAGING_GUILDS_CSS_CACHE_CONTROL" \
  "$STAGING_GUILDS_CSS_PRAGMA" \
  "$STAGING_GUILDS_TLS_CERT" \
  "$STAGING_GUILDS_TLS_KEY" \
  guilds

nginx -t
systemctl enable --now nginx
systemctl reload nginx
php_retire_stale

install_reminder_cron
write_applied_state
