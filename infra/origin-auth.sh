# shellcheck shell=bash
# Origin lockdown (infra/README.md, "Origin lockdown"). Sourced by cloud-init.sh
# and infra/tests/origin-auth.sh.
#
# CloudFront adds an X-Origin-Auth header to every request it sends the origin.
# When the root-only secrets file below lists a secret, converge renders
# nginx/includes/origin-auth.conf so nginx refuses any request without a listed
# secret, except over loopback. Without the file, the repo's own include stays in
# place and refuses nothing.

# shellcheck disable=SC2034  # read by cloud-init.sh
ORIGIN_AUTH_FILE='/etc/amazon-server.origin-auth'

# origin_auth_secrets <file>: the accepted secrets, one per line. Blank lines and
# # comments are skipped. Any other line must be 32 to 40 letters and digits: no
# quote or brace can reach nginx's config, and a longer key overflows nginx's
# default map_hash_bucket_size (64) so nginx won't start. 40 random letters and
# digits carry about 238 bits. A bad line fails the render and prints no secret.
origin_auth_secrets() {
  local file="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -z "$line" ]] && continue
    if [[ ! "$line" =~ ^[A-Za-z0-9]{32,40}$ ]]; then
      printf 'origin auth: %s has a line that is not 32 to 40 letters and digits\n' "$file" >&2
      return 1
    fi
    printf '%s\n' "$line"
  done < "$file"
}

# origin_auth_render <secrets-file> <include>: write the enforcing include when the
# secrets file lists at least one secret. With no file, or no secret in it, the
# include is left as it is. Two secrets at once let a rotation run without a gap.
origin_auth_render() {
  local file="$1" include="$2" secrets secret tmp
  [[ -f "$file" ]] || return 0
  secrets="$(origin_auth_secrets "$file")" || return 1
  [[ -n "$secrets" ]] || return 0
  tmp="$(mktemp)"
  {
    printf '# Rendered by amazon-server-converge from %s. Do not edit.\n\n' "$file"
    printf 'map $http_x_origin_auth $origin_auth_header {\n  default 0;\n'
    while IFS= read -r secret; do
      printf '  "%s" 1;\n' "$secret"
    done <<< "$secrets"
    printf '}\n\n'
    # The connecting address, before cloudfront-real-ip.conf swaps in the
    # viewer: a forged X-Forwarded-For can't pass as loopback.
    printf 'map $realip_remote_addr $origin_auth_loopback {\n  default 0;\n  127.0.0.1 1;\n  ::1 1;\n}\n\n'
    printf 'map "$origin_auth_header$origin_auth_loopback" $origin_refused {\n  default 1;\n  "~1" 0;\n}\n'
  } > "$tmp"
  install -m 0600 "$tmp" "$include"
  if [[ ${EUID} -eq 0 ]]; then
    chown root:root "$include"
  fi
  rm -f "$tmp"
}
