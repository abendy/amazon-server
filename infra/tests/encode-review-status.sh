#!/usr/bin/env bash
# Encode review checks in infra/converge.sh status. Sources the script for its
# functions, points it at a temporary spool and two temporary site checkouts,
# stubs systemctl, stat, id, ffmpeg, the vmaf tool and df, and runs the checks
# three times:
#   1. current: running with every limit and the recorded start state, spool
#      owned and setgid, www-data in the group, both tools, the plugin
#      matching in both sites, disk above the floor, the production login
#      present
#   2. drifted: stopped, started with older code, two limits off, a wrong
#      spool mode, www-data outside the group, no vmaf, one plugin changed and
#      one missing, disk under the floor, no production login
#   3. php pools: an upload pool an earlier build left (uploads now go in
#      parts through the site pool) counts as a pool left behind
#   4. production: skipped, it never runs the tool
# Then it drives infra/encode-review.sh's restart decision with systemctl
# stubbed: a first run, an unchanged run, a code-only update, a same-path
# login rotation, and a stopped worker. The login never reaches the output
# or the recorded state. Last, the installer removes those old upload pools.
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$TESTS_DIR")"
REPO_DIR="$(dirname "$INFRA_DIR")"
FAILURES=0

# shellcheck source=infra/converge.sh
source "${INFRA_DIR}/converge.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ER_SPOOL="${WORK_DIR}/spool"
ER_PLUGIN_SOURCE="${REPO_DIR}/encode-review/wp-plugin/encode-review"
ER_PLUGIN_SITES=("${WORK_DIR}/amazon-studios-ampas" "${WORK_DIR}/amazon-studios-guilds")
ER_VMAF_BIN="${WORK_DIR}/vmaf"
ER_CREDENTIAL_FILE="${WORK_DIR}/encode-review-production.env"
ER_INSTALLER="${INFRA_DIR}/encode-review.sh"
ER_UNIT_FILE="${WORK_DIR}/unit/${ER_UNIT}"
ER_DROPIN_DIR="${WORK_DIR}/unit/${ER_UNIT}.d"
ER_STATE_FILE="${WORK_DIR}/state/worker-state"
ER_PHP_ROOT="${WORK_DIR}/etc/php"
AMAZON_SERVER_ROOT="$REPO_DIR"
SYSTEMCTL_CALLS=()

SERVICE_ACTIVE=true
SPOOL_MODE='2775'
WWW_GROUPS='www-data encode-review'
FREE_BYTES=$((40 * 1024 * 1024 * 1024))
declare -A LIMITS=()

# The stubs below shadow the real commands that converge.sh calls.
# shellcheck disable=SC2329
systemctl() {
  case "$1" in
    is-active) [[ "$SERVICE_ACTIVE" == true ]] ;;
    start | restart | reload) SYSTEMCTL_CALLS+=("$1") ;;
    daemon-reload | enable) ;;
    show)
      local key
      for key in "${!LIMITS[@]}"; do
        printf '%s=%s\n' "$key" "${LIMITS[$key]}"
      done
      ;;
  esac
}
# shellcheck disable=SC2329
stat() {
  case "$2" in
    '%U:%G %a') printf 'encode-review:encode-review %s\n' "$SPOOL_MODE" ;;
    *) printf 'root:root 600 120B\n' ;;
  esac
}
# shellcheck disable=SC2329
id() { printf '%s\n' "$WWW_GROUPS"; }
# shellcheck disable=SC2329
ffmpeg() { printf 'ffmpeg version 6.1.1-3ubuntu5 Copyright (c) 2000-2023\n'; }
# shellcheck disable=SC2329
df() { printf 'Avail\n%s\n' "$FREE_BYTES"; }

current_limits() {
  LIMITS=(
    [MemoryMax]='838860800'
    [MemorySwapMax]='0'
    [CPUQuotaPerSecUSec]='1.500000s'
    [Nice]='19'
    [IOSchedulingClass]='3'
  )
}

reset_er_state() {
  ER_LINES=()
  ER_PROBLEMS=()
  ER_WARNED=0
}

# expect <label> <pattern>: every ER_LINES entry for the label matches the pattern.
expect() {
  local lines line
  lines="$(printf '%s\n' "${ER_LINES[@]}" | grep -E "^  [a-zA-Z]+ +${1} " || true)"
  if [[ -z "$lines" ]]; then
    printf 'FAIL  %s: want /%s/, got nothing\n' "$1" "$2"
    FAILURES=$((FAILURES + 1))
    return
  fi
  while IFS= read -r line; do
    if [[ "$line" =~ $2 ]]; then
      printf 'ok    %s\n' "$line"
    else
      printf 'FAIL  %s: want /%s/, got: %s\n' "$1" "$2" "$line"
      FAILURES=$((FAILURES + 1))
    fi
  done <<< "$lines"
}

expect_counts() {
  if [[ ${#ER_PROBLEMS[@]} -eq "$1" && "$ER_WARNED" -eq "$2" ]]; then
    printf 'ok    %d failed, %d warned\n' "$1" "$2"
  else
    printf 'FAIL  want %d failed %d warned, got %d failed %d warned: %s\n' "$1" "$2" \
      "${#ER_PROBLEMS[@]}" "$ER_WARNED" "${ER_PROBLEMS[*]}"
    FAILURES=$((FAILURES + 1))
  fi
}

install_plugin_copies() {
  local site
  for site in "${ER_PLUGIN_SITES[@]}"; do
    rm -rf "${site:?}/${ER_PLUGIN_SUBDIR:?}"
    mkdir -p "${site}/${ER_PLUGIN_SUBDIR}"
    cp -R "${ER_PLUGIN_SOURCE}/." "${site}/${ER_PLUGIN_SUBDIR}/"
  done
}

# Like the real tool, the stub prints its version on stderr.
printf '#!/usr/bin/env bash\necho f85a853 >&2\n' > "$ER_VMAF_BIN"
chmod +x "$ER_VMAF_BIN"
mkdir -p "$ER_SPOOL"
for dir in "${ER_SPOOL_DIRS[@]}"; do
  mkdir -p "${ER_SPOOL}/${dir}"
done
install_plugin_copies
touch "$ER_CREDENTIAL_FILE"
mkdir -p "$(dirname "$ER_UNIT_FILE")" "$(dirname "$ER_STATE_FILE")"
cp "${REPO_DIR}/encode-review/systemd/${ER_UNIT}" "$ER_UNIT_FILE"

# write_pool <version> <site>: an upload pool file an earlier build installed.
write_pool() {
  local dir="${ER_PHP_ROOT}/${1}/fpm/pool.d"
  mkdir -p "$dir"
  printf '[%s-encode-review-upload]\nphp_admin_value[upload_max_filesize] = 5G\n' "$2" \
    > "${dir}/${2}-encode-review-upload.conf"
}
# shellcheck source=infra/encode-review.sh
(source "$ER_INSTALLER" && encode_review_state_hash "$AMAZON_SERVER_ROOT" "$ER_UNIT_FILE" \
  "$ER_DROPIN_DIR" "$ER_CREDENTIAL_FILE") > "$ER_STATE_FILE"

printf '== current\n'
reset_er_state
current_limits
run_encode_review_checks staging
expect 'service' '^  ok .* encode-review-worker\.service active$'
expect 'current' '^  ok .* worker started with the checked-out code, unit and login$'
expect 'limits' '^  ok .* MemoryMax=800M MemorySwapMax=0 CPUQuota=150% Nice=19 IOSchedulingClass=idle$'
expect 'spool' '^  ok .* 6 folders encode-review:encode-review 2775, www-data in group$'
expect 'tools' '^  ok .* ffmpeg 6\.1\.1-3ubuntu5, vmaf f85a853$'
expect 'plugin' '^  ok .* amazon-studios-(ampas|guilds): matches the checkout$'
expect 'disk' '^  ok .* 40 GiB free'
expect 'production login' '^  ok .* present: root:root 600'
expect_counts 0 0

printf '== drifted\n'
reset_er_state
SERVICE_ACTIVE=false
current_limits
LIMITS[MemoryMax]='infinity'
LIMITS[IOSchedulingClass]='0'
SPOOL_MODE='755'
WWW_GROUPS='www-data'
FREE_BYTES=$((6 * 1024 * 1024 * 1024))
rm -f "$ER_VMAF_BIN" "$ER_CREDENTIAL_FILE"
rm -rf "${ER_PLUGIN_SITES[0]:?}/${ER_PLUGIN_SUBDIR}"
printf '/* local edit */\n' >> "${ER_PLUGIN_SITES[1]}/${ER_PLUGIN_SUBDIR}/assets/review.css"
printf 'older\n' > "$ER_STATE_FILE"
run_encode_review_checks staging
expect 'service' '^  FAIL .* encode-review-worker\.service not running$'
expect 'current' '^  FAIL .* worker started with older code, unit or login: converge restarts it$'
expect 'limits' '^  FAIL .* MemoryMax is infinity, want 838860800; IOSchedulingClass is 0, want idle\|3$'
expect 'spool' '^  FAIL .* is encode-review:encode-review 755, want encode-review:encode-review 2775; .*; www-data is not in the encode-review group$'
expect 'tools' '^  FAIL .* ffmpeg 6\.1\.1-3ubuntu5; vmaf missing at '
expect 'plugin' '^  FAIL .* amazon-studios-(ampas: .* missing|guilds: .* differs from the checkout)$'
expect 'disk' '^  WARN .* 6 GiB free, under the 10 GiB floor: uploads are refused$'
expect 'production login' '^  WARN .* absent: Send to production is off$'
expect_counts 7 2

printf '== php pools\n'
# An upload pool from an earlier build is a pool left behind, even under the
# site's own version. The stubbed systemctl has no unit state, so only the
# pools part is checked.
PHP_SETTING=([ampas_version]=8.4 [guilds_version]=8.4 [rsvp_version]=8.4)
PHP_LINES=()
mkdir -p "${ER_PHP_ROOT}/8.4/fpm/pool.d"
printf '[guilds]\n' > "${ER_PHP_ROOT}/8.4/fpm/pool.d/guilds.conf"
write_pool 8.4 ampas
check_php_version "${ER_PHP_ROOT}/8.4/fpm/pool.d"
ER_LINES=("${PHP_LINES[@]}")
expect 'php8.4-fpm' '^  FAIL .*; pools left behind: ampas-encode-review-upload$'

printf '== production\n'
reset_er_state
run_encode_review_checks production
expect 'encode review' '^  skip .* production never runs the tool$'
expect_counts 0 0

# ---- restart decision (infra/encode-review.sh) ------------------------------

# shellcheck source=infra/encode-review.sh
source "$ER_INSTALLER"
ENCODE_REVIEW_UNIT_FILE="$ER_UNIT_FILE"
ENCODE_REVIEW_DROPIN_DIR="$ER_DROPIN_DIR"
ENCODE_REVIEW_CREDENTIAL_FILE="${WORK_DIR}/login.env"
ENCODE_REVIEW_STATE_DIR="${WORK_DIR}/var-lib"
ENCODE_REVIEW_STATE_FILE="${ENCODE_REVIEW_STATE_DIR}/worker-state"
AMAZON_SERVER_ROOT="${WORK_DIR}/checkout"
mkdir -p "${AMAZON_SERVER_ROOT}/encode-review"
cp -R "${REPO_DIR}/encode-review/worker" "${AMAZON_SERVER_ROOT}/encode-review/worker"
SECRET='abcd efgh ijkl mnop qrst uvwx'
printf 'AMPAS_URL=https://ampas.example\nAMPAS_USER=uploader\nAMPAS_APP_PASSWORD=%s\n' "$SECRET" \
  > "$ENCODE_REVIEW_CREDENTIAL_FILE"

# converge_step <label> <want>: one converge's restart decision, then an
# unchanged rerun that must leave a running worker alone. want is the
# systemctl start/restart calls of the first ("none" for neither).
converge_step() {
  local got rerun
  SYSTEMCTL_CALLS=()
  encode_review_apply_worker > "${WORK_DIR}/apply.out" 2>&1
  got="${SYSTEMCTL_CALLS[*]:-none}"
  SYSTEMCTL_CALLS=()
  encode_review_apply_worker >> "${WORK_DIR}/apply.out" 2>&1
  rerun="${SYSTEMCTL_CALLS[*]:-none}"
  [[ "$SERVICE_ACTIVE" == true ]] || rerun="none (stopped: ${rerun})"
  if [[ "$got" == "$2" && "$rerun" == none* ]]; then
    printf 'ok    %s: %s, rerun %s\n' "$1" "$2" "$rerun"
  else
    printf 'FAIL  %s: want %s then none, got %s then %s\n' "$1" "$2" "$got" "$rerun"
    FAILURES=$((FAILURES + 1))
  fi
  if grep -qF "$SECRET" "${WORK_DIR}/apply.out" "$ENCODE_REVIEW_STATE_FILE"; then
    printf 'FAIL  %s: the login reached the output or the recorded state\n' "$1"
    FAILURES=$((FAILURES + 1))
  fi
}

printf '== restart decision\n'
SERVICE_ACTIVE=true
rm -rf "$ENCODE_REVIEW_STATE_DIR"
converge_step 'first converge of a running worker restarts it once' 'restart'
printf '# code-only update\n' >> "${AMAZON_SERVER_ROOT}/encode-review/worker/encode_review/send.py"
converge_step 'code-only update restarts once' 'restart'
printf 'AMPAS_URL=https://ampas.example\nAMPAS_USER=uploader\nAMPAS_APP_PASSWORD=%s\n' "${SECRET/abcd/zzzz}" \
  > "$ENCODE_REVIEW_CREDENTIAL_FILE"
converge_step 'login rotated in the same file restarts once' 'restart'
mkdir -p "$ER_DROPIN_DIR"
printf '[Service]\nLoadCredential=production-upload:%s\n' "$ENCODE_REVIEW_CREDENTIAL_FILE" \
  > "${ER_DROPIN_DIR}/production-upload.conf"
converge_step 'new drop-in restarts once' 'restart'
SERVICE_ACTIVE=false
converge_step 'stopped worker starts' 'start'
if [[ "$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$ENCODE_REVIEW_STATE_FILE")" == 600 ]]; then
  printf 'ok    recorded state is 600\n'
else
  printf 'FAIL  recorded state is not 600\n'
  FAILURES=$((FAILURES + 1))
fi

printf '== old upload pools\n'
# The installer removes them from every PHP version and reloads only an FPM
# that runs and had one.
PHP_SYSROOT="$WORK_DIR"
write_pool 7.4 guilds
php_fpm_unit() { printf 'php%s-fpm' "$1"; }
SERVICE_ACTIVE=true
SYSTEMCTL_CALLS=()
encode_review_retire_upload_pools
left="$(compgen -G "${ER_PHP_ROOT}/*/fpm/pool.d/*-encode-review-upload.conf" || true)"
if [[ -z "$left" && -e "${ER_PHP_ROOT}/8.4/fpm/pool.d/guilds.conf" && "${SYSTEMCTL_CALLS[*]:-}" == "reload reload" ]]; then
  printf 'ok    old upload pools removed, site pools kept, one reload per PHP version (8.4, 7.4)\n'
else
  printf 'FAIL  old upload pools left: %s; calls: %s\n' "$left" "${SYSTEMCTL_CALLS[*]:-none}"
  FAILURES=$((FAILURES + 1))
fi
SYSTEMCTL_CALLS=()
encode_review_retire_upload_pools
if [[ ${#SYSTEMCTL_CALLS[@]} -eq 0 ]]; then
  printf 'ok    nothing to remove: no reload\n'
else
  printf 'FAIL  reload without an old pool: %s\n' "${SYSTEMCTL_CALLS[*]}"
  FAILURES=$((FAILURES + 1))
fi

printf '== %d failure(s)\n' "$FAILURES"
exit "$FAILURES"
