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
    printf '%s: %s (applied %s, remote %s, owned %d changed %d missing, manual %d failed %d warned)%s\n' \
      "$environment" "$verdict" "${applied_short:-none}" "${remote_short:-unreachable}" \
      "${#changed_files[@]}" "${#missing_files[@]}" "$MANUAL_FAILED" "$MANUAL_WARNED" "$reasons"
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

main "$@"
