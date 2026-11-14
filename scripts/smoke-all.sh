#!/usr/bin/env bash
# Smoke-check all three sites on a host after any deploy or converge.
#   ssh <host> 'bash -s -- <staging|production> <since "YYYY/MM/DD HH:MM" UTC> [pre-rs14]' < scripts/smoke-all.sh   (from this repo)
# Read-only. A log that cannot be read FAILS. Exits with the number of failures; any failure is a
# stop condition.
set -u
env=${1:?usage: smoke-all.sh <staging|production> <since> [pre-rs14]}
since=${2:?give the UTC start time of the step, as "YYYY/MM/DD HH:MM"}
phase=${3:-}
fails=0
case "$env" in
  staging) rsvp=stg.rsvp.amazonmgmstudiosawards.com; ampas=stg.amazonmgmstudiosawards.com; guilds=stg.amazonmgmstudiosguilds.com ;;
  production) rsvp=rsvp.amazonmgmstudiosawards.com; ampas=amazonmgmstudiosawards.com; guilds=amazonmgmstudiosguilds.com ;;
  *) echo "unknown env $env"; exit 1 ;;
esac
[[ "$since" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || { echo "FAIL since must be \"YYYY/MM/DD HH:MM\""; exit 1; }
want() {  # want <host> <path> <expected status> [method]
  local code
  code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' -X "${4:-GET}" -H "Host: $1" -H 'X-Forwarded-Proto: https' "http://127.0.0.1$2")
  if [ "$code" = "$3" ]; then echo "PASS $1$2 $code"; else echo "FAIL $1$2 got $code, want $3"; fails=$((fails+1)); fi
}
want "$rsvp" /admin/user/login 200
want "$rsvp" /admin/api/v1/movies 200
want "$rsvp" /admin/api/v1/screenings 400
[ "$phase" = pre-rs14 ] || want "$rsvp" /admin/ajax/cancelRSVP 404
for h in "$ampas" "$guilds"; do
  want "$h" / 200
  want "$h" /wp-json/ 200
  want "$h" /wp/wp-login.php 200
  want "$h" /no-such-page-cutover/ 404
done
for site in rsvp ampas guilds; do
  d=/var/log/nginx/$site
  files=("$d/error.log"); sudo -n test -f "$d/error.log.1" 2>/dev/null && files+=("$d/error.log.1")
  if ! lines=$(sudo -n awk -v t="$since" '($1" "$2) >= t' "${files[@]}" 2>/dev/null); then
    echo "FAIL $site: cannot read ${files[*]}"; fails=$((fails+1)); continue
  fi
  n=$(grep -ciE 'PHP (Fatal|Parse) error|Uncaught' <<<"$lines")
  if [ "$n" = 0 ]; then echo "PASS $site: log read, no PHP fatals since $since"; else echo "FAIL $site: $n PHP fatal line(s) since $since"; fails=$((fails+1)); fi
  echo "INFO $site: $(grep -ciE 'PHP (Warning|Deprecated)' <<<"$lines") PHP warning/deprecation line(s) since $since"
done
echo "== $fails failure(s)"
exit "$fails"
