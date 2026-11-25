#!/usr/bin/env bash
# Origin lockdown: the renderer in infra/origin-auth.sh and the status check in
# infra/converge.sh. Covers no file, a comment-only file, a bad line, and two
# secrets; then, with Docker, that nginx accepts the rendered include and refuses
# or serves the right requests. No secret may reach the status output.
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$TESTS_DIR")"
REPO_DIR="$(dirname "$INFRA_DIR")"
FAILURES=0

# shellcheck source=infra/origin-auth.sh
source "${INFRA_DIR}/origin-auth.sh"

SCRATCH="$(mktemp -d)"
trap 'command rm -rf "$SCRATCH"' EXIT
SECRETS="${SCRATCH}/origin-auth"
INCLUDE="${SCRATCH}/origin-auth.conf"
DEFAULT_INCLUDE="${REPO_DIR}/nginx/includes/origin-auth.conf"
SECRET_A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
SECRET_B='B2b2B2b2B2b2B2b2B2b2B2b2B2b2B2b2'

pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { # check <label> <command...>
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}
reset_include() { command cp "$DEFAULT_INCLUDE" "$INCLUDE"; }
unchanged() { cmp -s "$DEFAULT_INCLUDE" "$INCLUDE"; }

# ---- renderer ------------------------------------------------------------------

reset_include
command rm -f "$SECRETS"
check 'no secrets file: renderer succeeds' origin_auth_render "$SECRETS" "$INCLUDE"
check 'no secrets file: include still the default' unchanged

printf '# rotated 2026-11-25\n\n' > "$SECRETS"
check 'comment-only file: renderer succeeds' origin_auth_render "$SECRETS" "$INCLUDE"
check 'comment-only file: include still the default' unchanged

printf '%s\nnot-a-secret";\n' "$SECRET_A" > "$SECRETS"
if origin_auth_render "$SECRETS" "$INCLUDE" 2> /dev/null; then
  fail 'quote in a line: renderer fails'
else
  pass 'quote in a line: renderer fails'
fi
printf '%s\n%s\n' "$SECRET_A" "${SECRET_A}a" > "$SECRETS"
if origin_auth_render "$SECRETS" "$INCLUDE" 2> "${SCRATCH}/err"; then
  fail '41-character line: renderer fails'
else
  pass '41-character line: renderer fails'
fi
check 'bad line: include still the default' unchanged
if grep -q "$SECRET_A" "${SCRATCH}/err"; then fail 'bad line: error names no secret'; else pass 'bad line: error names no secret'; fi

printf '%s\n  %s  # next\n' "$SECRET_A" "$SECRET_B" > "$SECRETS"
check 'two secrets: renderer succeeds' origin_auth_render "$SECRETS" "$INCLUDE"
check 'two secrets: both listed' bash -c "grep -qF '\"$SECRET_A\" 1;' '$INCLUDE' && grep -qF '\"$SECRET_B\" 1;' '$INCLUDE'"
check 'two secrets: loopback keys on the connecting address' grep -qF 'map $realip_remote_addr $origin_auth_loopback' "$INCLUDE"
check 'two secrets: include is 600' test "$(command stat -c '%a' "$INCLUDE" 2> /dev/null || command stat -f '%Lp' "$INCLUDE")" = 600

# ---- nginx (Docker) ------------------------------------------------------------

if command -v docker > /dev/null && docker info > /dev/null 2>&1; then
  NGINX_DIR="${SCRATCH}/nginx"
  mkdir -p "${NGINX_DIR}/includes"
  command cp "$INCLUDE" "${NGINX_DIR}/includes/origin-auth.conf"
  chmod 0644 "${NGINX_DIR}/includes/origin-auth.conf"
  cat > "${NGINX_DIR}/nginx.conf" <<'NGINX'
events {}
http {
  set_real_ip_from 172.16.0.0/12;
  set_real_ip_from 192.168.0.0/16;
  set_real_ip_from 10.0.0.0/8;
  real_ip_header X-Forwarded-For;
  include includes/origin-auth.conf;
  server {
    listen 8080;
    if ($origin_refused) { return 403; }
    location / { return 200 "served\n"; }
  }
}
NGINX
  # docker cp, not a bind mount: Docker Desktop can't see every temp folder.
  name="origin-auth-test-$$"
  nginx_up() { # nginx_up: a fresh container on its own network, serving NGINX_DIR
    docker create --name "$name" --network "$name" nginx:1.27-alpine > /dev/null
    docker cp "${NGINX_DIR}/." "${name}:/etc/nginx/" > /dev/null
    docker start "$name" > /dev/null
    sleep 1
  }
  nginx_down() { docker rm -f "$name" > /dev/null 2>&1 || true; }
  # BusyBox wget also prints "server returned error: HTTP/1.1 403" on a 4xx.
  status_of() { grep -oE 'HTTP/1\.[01] [0-9]{3}' | tail -1 | cut -d' ' -f2; }
  code() { docker exec "$name" wget -q -S -O /dev/null http://127.0.0.1:8080/ 2>&1 | status_of; }
  # From another container on the network: not loopback.
  remote() {
    docker run --rm --network "$name" alpine:3.20 wget -q -S -O /dev/null "$@" "http://${name}:8080/" 2>&1 | status_of
  }
  docker network create "$name" > /dev/null
  nginx_up
  check 'nginx -t accepts the rendered include' docker exec "$name" nginx -t -q
  check 'loopback without the header: served' test "$(code)" = 200
  check 'remote without the header: 403' test "$(remote)" = 403
  check 'remote with a wrong header: 403' test "$(remote --header 'X-Origin-Auth: wrong')" = 403
  check 'remote with secret A: served' test "$(remote --header "X-Origin-Auth: ${SECRET_A}")" = 200
  check 'remote with secret B: served' test "$(remote --header "X-Origin-Auth: ${SECRET_B}")" = 200
  check 'remote forging loopback in X-Forwarded-For: 403' test "$(remote --header 'X-Forwarded-For: 127.0.0.1')" = 403
  nginx_down
  command cp "$DEFAULT_INCLUDE" "${NGINX_DIR}/includes/origin-auth.conf"
  nginx_up
  check 'nginx -t accepts the repo default include' docker exec "$name" nginx -t -q
  check 'repo default: remote without the header served' test "$(remote)" = 200
  nginx_down
  docker network rm "$name" > /dev/null
else
  printf 'skip  nginx checks: Docker is not available\n'
fi

# ---- status --------------------------------------------------------------------

# shellcheck source=infra/converge.sh
source "${INFRA_DIR}/converge.sh"
# shellcheck disable=SC2034  # read by check_origin_auth
ORIGIN_AUTH_FILE="$SECRETS"
# shellcheck disable=SC2034
ORIGIN_AUTH_INCLUDE="$INCLUDE"
OWNER_MODE='root:root 600'
# The stub shadows stat: '%U:%G %a' gives the test's owner and mode.
# shellcheck disable=SC2329
stat() {
  case "$2" in
    '%U:%G %a') printf '%s\n' "$OWNER_MODE" ;;
    *) printf '%s 1B\n' "$OWNER_MODE" ;;
  esac
}
status_line() {
  # shellcheck disable=SC2034  # manual_result's counters
  MANUAL_LINES=() MANUAL_FAILED=0 MANUAL_WARNED=0
  check_origin_auth
  printf '%s\n' "${MANUAL_LINES[@]}"
}
expect() { # expect <label> <pattern>
  local out
  out="$(status_line)"
  if grep -qE "$2" <<< "$out" && ! grep -qF "$SECRET_A" <<< "$out"; then pass "$1"; else fail "$1: ${out}"; fi
}

expect 'status: two secrets, enforced' 'ok +origin auth .*2 secret\(s\), enforced'
OWNER_MODE='ubuntu:ubuntu 644'
expect 'status: wrong owner warns' 'WARN +origin auth .*should be root:root 600'
OWNER_MODE='root:root 600'
reset_include
expect 'status: secrets not rendered yet warns' 'WARN +origin auth .*not enforced yet'
command rm -f "$SECRETS"
expect 'status: missing file warns' 'WARN +origin auth .*missing'

exit "$FAILURES"
