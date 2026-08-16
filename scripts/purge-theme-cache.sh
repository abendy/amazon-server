#!/bin/sh

set -eu

DEFAULT_REPO_ROOT='/var/www/html'
TITLES_TRANSIENT='vm_titles_catalog'

usage() {
    cat <<'EOF'
Usage:
  scripts/purge-theme-cache.sh <ampas|guilds> <staging|production>

When called by apply-theme-deploy.sh, set THEME_DEPLOY_SITE and omit the
arguments. THEME_DEPLOY_REPO_DIR may override the deployed site checkout.
EOF
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

dotenv_value() {
    key="$1"
    file="$2"
    value=''

    [ -f "$file" ] || return 1
    value="$(awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
            print
        }
    ' "$file" | tail -n 1)"

    case "$value" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac

    [ -n "$value" ] || return 1
    printf '%s' "$value"
}

config_value() {
    key="$1"
    config_root="$2"
    env_file="${THEME_DEPLOY_ENV_FILE:-$config_root/.env}"
    value=''

    if [ -f "$env_file" ]; then
        value="$(dotenv_value "$key" "$env_file" || true)"
    fi
    if [ -z "${THEME_DEPLOY_ENV_FILE:-}" ] && [ -f "$config_root/.env.local" ]; then
        override_value="$(dotenv_value "$key" "$config_root/.env.local" || true)"
        if [ -n "$override_value" ]; then
            value="$override_value"
        fi
    fi

    [ -n "$value" ] || return 1
    printf '%s' "$value"
}

site_defaults() {
    case "$1" in
        ampas)
            DEFAULT_REPO_DIR="$DEFAULT_REPO_ROOT/amazon-studios-ampas"
            DEFAULT_DB_CONTAINER='ampas-mariadb'
            ;;
        guilds)
            DEFAULT_REPO_DIR="$DEFAULT_REPO_ROOT/amazon-studios-guilds"
            DEFAULT_DB_CONTAINER='guilds-mariadb'
            ;;
        *)
            fail "Theme must be ampas or guilds: $1"
            ;;
    esac
}

infer_site() {
    repo_dir="$1"

    case "$repo_dir" in
        *amazon-studios-ampas*|*ampas-server*) printf 'ampas' ;;
        *amazon-studios-guilds*|*guilds-server*) printf 'guilds' ;;
        *) return 1 ;;
    esac
}

database_value() {
    key="$1"
    docker_key="$2"
    db_container="${THEME_DEPLOY_DB_CONTAINER:-$DEFAULT_DB_CONTAINER}"
    value=''

    value="$(config_value "$key" "$config_root" || true)"
    if [ -z "$value" ] && [ "${THEME_DEPLOY_LOCAL_DOCKER:-0}" = '1' ] \
        && command -v docker >/dev/null 2>&1 \
        && docker container inspect "$db_container" >/dev/null 2>&1; then
        value="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
            "$db_container" 2>/dev/null \
            | awk -F= -v key="$docker_key" '$1 == key { print substr($0, length(key) + 2) }' \
            | tail -n 1)"
    fi
    if [ -z "$value" ] && [ "$key" = 'DB_HOST' ] \
        && [ "${THEME_DEPLOY_LOCAL_DOCKER:-0}" = '1' ]; then
        value="$db_container"
    fi
    if [ -z "$value" ]; then
        fail "Site config is missing $key: $config_root/.env"
    fi
    printf '%s' "$value"
}

run_sql() {
    sql="DELETE FROM ${db_prefix}options WHERE option_name LIKE '%transient%${TITLES_TRANSIENT}%';"

    if [ -n "${THEME_DEPLOY_DB_CONTAINER:-}" ]; then
        db_container="$THEME_DEPLOY_DB_CONTAINER"
    else
        db_container="$DEFAULT_DB_CONTAINER"
    fi

    if [ "${THEME_DEPLOY_LOCAL_DOCKER:-0}" = '1' ] \
        && command -v docker >/dev/null 2>&1 \
        && docker container inspect "$db_container" >/dev/null 2>&1; then
        if docker exec "$db_container" env MYSQL_PWD="$db_password" mariadb \
            --host=127.0.0.1 --port="$db_port" --user="$db_user" "$db_name" \
            -e "$sql" >/dev/null 2>&1; then
            return 0
        fi
        if docker exec "$db_container" env MYSQL_PWD="$db_password" mysql \
            --host=127.0.0.1 --port="$db_port" --user="$db_user" "$db_name" \
            -e "$sql" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi

    if command -v mariadb >/dev/null 2>&1; then
        MYSQL_PWD="$db_password" mariadb --host="$db_host" --port="$db_port" \
            --user="$db_user" "$db_name" -e "$sql" >/dev/null 2>&1
        return $?
    fi
    if command -v mysql >/dev/null 2>&1; then
        MYSQL_PWD="$db_password" mysql --host="$db_host" --port="$db_port" \
            --user="$db_user" "$db_name" -e "$sql" >/dev/null 2>&1
        return $?
    fi

    run_php_sql
}

run_php_sql() {
    php_binary=''
    if command -v php7.4 >/dev/null 2>&1; then
        php_binary='php7.4'
    elif command -v php >/dev/null 2>&1; then
        php_binary='php'
    else
        return 1
    fi

    # shellcheck disable=SC2016
    DB_HOST="$db_host" DB_PORT="$db_port" DB_NAME="$db_name" \
        DB_USER="$db_user" DB_PASSWORD="$db_password" DB_PREFIX="$db_prefix" \
        "$php_binary" -r '
        try {
            $pdo = new PDO(
                "mysql:host=" . getenv("DB_HOST") . ";port=" . getenv("DB_PORT") .
                ";dbname=" . getenv("DB_NAME") . ";charset=utf8mb4",
                getenv("DB_USER"),
                getenv("DB_PASSWORD"),
                [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
            );
            $table = getenv("DB_PREFIX") . "options";
            $pattern = chr(39) . "%transient%vm_titles_catalog%" . chr(39);
            $pdo->exec("DELETE FROM `" . $table . "` WHERE option_name LIKE " . $pattern);
        } catch (Throwable $error) {
            exit(1);
        }
    ' >/dev/null 2>&1
}

resolve_arguments() {
    arguments_supplied=0

    case "$#" in
        0)
            site="${THEME_DEPLOY_SITE:-}"
            environment="${THEME_DEPLOY_ENVIRONMENT:-}"
            ;;
        2)
            arguments_supplied=1
            site="$1"
            environment="$2"
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac

    if [ -z "$site" ] && [ -n "${THEME_DEPLOY_REPO_DIR:-}" ]; then
        site="$(infer_site "$THEME_DEPLOY_REPO_DIR" || true)"
    fi
    [ -n "$site" ] || fail 'Site is required; use <ampas|guilds> or THEME_DEPLOY_SITE'

    site_defaults "$site"
    repo_dir="${THEME_DEPLOY_REPO_DIR:-$DEFAULT_REPO_DIR}"
    config_root="${THEME_DEPLOY_CONFIG_DIR:-$repo_dir}"
    [ -d "$config_root" ] || fail "Site checkout is missing: $config_root"

    if [ -z "$environment" ]; then
        environment="$(config_value WP_ENV "$config_root" || true)"
    fi
    if [ -z "$environment" ]; then
        if [ "$arguments_supplied" -eq 0 ]; then
            environment='unknown'
        else
            fail "Environment is required for $site"
        fi
    fi

    case "$environment" in
        staging|production) ;;
        local)
            [ "$arguments_supplied" -eq 0 ] \
                || fail 'Environment must be staging or production when passed as an argument'
            ;;
        unknown)
            [ "$arguments_supplied" -eq 0 ] \
                || fail "Environment must be staging or production when passed as an argument"
            ;;
        *) fail "Environment must be staging, production, local, or unknown: $environment" ;;
    esac
}

resolve_arguments "$@"

db_host="$(database_value DB_HOST MARIADB_HOST)"
db_name="$(database_value DB_NAME MARIADB_DATABASE)"
db_user="$(database_value DB_USER MARIADB_USER)"
db_password="$(database_value DB_PASSWORD MARIADB_PASSWORD)"
db_port="$(config_value DB_PORT "$config_root" || printf '3306')"
db_prefix="$(config_value DB_PREFIX "$config_root" || printf 'wp_')"

case "$db_port" in
    ''|*[!0-9]*) fail 'DB_PORT must be numeric in the site config' ;;
esac
case "$db_prefix" in
    ''|*[!A-Za-z0-9_]*) fail 'DB_PREFIX contains unsupported characters' ;;
esac

if run_sql; then
    printf 'titles-catalog cache purged (%s, %s)\n' "$site" "$environment"
    exit 0
fi

fail "Unable to purge titles-catalog cache for $site: database connection or delete failed"
