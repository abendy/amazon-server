#!/usr/bin/env bash
# Refresh the local WP databases and uploads from staging.
#
#   sync-staging.sh [--no-backup] [--no-db] [--no-uploads] [--small] [ampas] [guilds]
#
# With no site arguments both WP sites sync. Local backups always cover
# all three databases (ampas, guilds, rsvp) unless --no-backup.
#
# What it does, in order:
#   1. Backs up the three local databases to _db/ (timestamped).
#   2. Dumps each staging WP database through an SSH tunnel (the instance
#      has no dump tools; the Lightsail DB endpoint is only reachable
#      from it) using a disposable mariadb container as the client.
#      The dump lands in _db/ timestamped and replaces the site's
#      re-seed copy (<name>-db.sql), then imports into the live local
#      container.
#   3. Rsyncs the staging uploads directory into the local checkout
#      (additive; nothing local is deleted; .gitkeep left alone).
#      --small skips files over 5MB (videos, mostly); override the
#      cutoff with SYNC_MAX_SIZE (rsync --max-size syntax, e.g. 20m).
#
# Credentials: local dumps/imports use the DB containers' own
# environment; staging credentials are read from the site's .env on the
# instance into this process only. Nothing is echoed or written.
#
# SSH: set STAGING_HOST (default ubuntu@32.188.183.9) and, if not using
# your agent key, STAGING_SSH_OPTS (e.g. "-i /path/to/key").

set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_DIR="$WORKSPACE/_db"
STAGING_HOST="${STAGING_HOST:-ubuntu@32.188.183.9}"
STAGING_SSH_OPTS="${STAGING_SSH_OPTS:-}"
TUNNEL_PORT="${TUNNEL_PORT:-33061}"
MARIADB_IMAGE="mariadb:12.3.2"
STAMP="$(date +%Y%m%d-%H%M%S)"

do_backup=1 do_db=1 do_uploads=1
max_size="${SYNC_MAX_SIZE:-5m}"
size_args=()
sites=()
for arg in "$@"; do
    case "$arg" in
        --no-backup) do_backup=0 ;;
        --no-db) do_db=0 ;;
        --no-uploads) do_uploads=0 ;;
        --small) size_args=("--max-size=$max_size") ;;
        ampas|guilds) sites+=("$arg") ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
[ ${#sites[@]} -eq 0 ] && sites=(ampas guilds)

# site -> local container, dump basename, checkout, staging path
container_for() { case "$1" in ampas) echo ampas-mariadb ;; guilds) echo guilds-mariadb ;; rsvp) echo rsvp-mysql ;; esac; }
dumpname_for() { case "$1" in ampas) echo amazon-studios-ampas-db ;; guilds) echo amazon-studios-guilds-db ;; rsvp) echo rsvp ;; esac; }
remote_root_for() { case "$1" in ampas) echo /var/www/html/amazon-studios-ampas ;; guilds) echo /var/www/html/amazon-studios-guilds ;; esac; }
local_root_for() { case "$1" in ampas) echo "$WORKSPACE/ampas" ;; guilds) echo "$WORKSPACE/guilds" ;; esac; }

# shellcheck disable=SC2086
staging_ssh() { ssh $STAGING_SSH_OPTS -o ConnectTimeout=15 "$STAGING_HOST" "$@"; }

backup_local() {
    local site="$1" container dump out
    container="$(container_for "$site")"
    dump="$(dumpname_for "$site")"
    out="$DB_DIR/${dump}_local-backup--${STAMP}.sql"
    echo "backup: $site -> ${out#"$WORKSPACE"/}"
    docker exec "$container" sh -c \
        'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' \
        > "$out"
}

sync_db() {
    local site="$1" container dump remote_root fetched port
    container="$(container_for "$site")"
    # A port per site: a multiplexed master holds forwards open, so
    # reusing one port across sites collides.
    case "$site" in ampas) port="$TUNNEL_PORT" ;; *) port=$((TUNNEL_PORT + 1)) ;; esac
    dump="$(dumpname_for "$site")"
    remote_root="$(remote_root_for "$site")"
    fetched="$DB_DIR/${dump}--staging-${STAMP}.sql"

    # Staging credentials, into this process only.
    local DB_NAME DB_USER DB_PASSWORD DB_HOST db_port
    eval "$(staging_ssh "grep -E '^DB_(NAME|USER|PASSWORD|HOST)=' $remote_root/.env" | sed "s/^/local /")"
    db_port="${DB_HOST##*:}"; [ "$db_port" = "$DB_HOST" ] && db_port=3306
    DB_HOST="${DB_HOST%%:*}"

    echo "dump: $site staging database -> ${fetched#"$WORKSPACE"/}"
    # Tunnel to the DB endpoint through the instance; dump with a
    # disposable client container (host.docker.internal reaches the
    # host-loopback tunnel under Docker Desktop). TLS is skipped: the
    # SSH tunnel already encrypts the hop, and the managed cert cannot
    # match a tunneled localhost endpoint.
    # shellcheck disable=SC2086
    ssh $STAGING_SSH_OPTS -f -N -o ExitOnForwardFailure=yes \
        -L "127.0.0.1:${port}:${DB_HOST}:${db_port}" "$STAGING_HOST"
    close_tunnel() {
        # Multiplexed forwards live on the master; cancel there first.
        # shellcheck disable=SC2086
        ssh $STAGING_SSH_OPTS -O cancel \
            -L "127.0.0.1:${port}:${DB_HOST}:${db_port}" "$STAGING_HOST" 2>/dev/null || true
        pkill -f "127.0.0.1:${port}:${DB_HOST}" 2>/dev/null || true
    }
    trap close_tunnel RETURN

    docker run --rm -e DUMP_PASSWORD="$DB_PASSWORD" "$MARIADB_IMAGE" sh -c \
        "exec mariadb-dump --single-transaction --skip-ssl \
            -h host.docker.internal -P ${port} -u '$DB_USER' -p\"\$DUMP_PASSWORD\" '$DB_NAME'" \
        > "$fetched"
    close_tunnel

    echo "import: $site local database <- ${fetched#"$WORKSPACE"/}"
    cp "$fetched" "$DB_DIR/${dump}.sql"
    docker exec -i "$container" sh -c \
        'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' \
        < "$fetched"
}

sync_uploads() {
    local site="$1" remote_root local_root
    remote_root="$(remote_root_for "$site")"
    local_root="$(local_root_for "$site")"
    echo "uploads: $site staging -> ${local_root#"$WORKSPACE"/}/web/app/uploads"
    # shellcheck disable=SC2086
    rsync -rltz --info=progress2 --exclude '.gitkeep' "${size_args[@]}" \
        ${STAGING_SSH_OPTS:+-e "ssh $STAGING_SSH_OPTS"} \
        "$STAGING_HOST:$remote_root/web/app/uploads/" \
        "$local_root/web/app/uploads/"
}

if [ "$do_backup" -eq 1 ]; then
    for site in ampas guilds rsvp; do backup_local "$site"; done
fi
if [ "$do_db" -eq 1 ]; then
    for site in "${sites[@]}"; do sync_db "$site"; done
fi
if [ "$do_uploads" -eq 1 ]; then
    for site in "${sites[@]}"; do sync_uploads "$site"; done
fi
echo "done"
