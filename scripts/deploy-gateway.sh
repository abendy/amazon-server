#!/usr/bin/env bash
# Deploy the Indee gateway function to one exact, reviewed commit. Run on the operator machine,
# from this repo, with the amazon-gateway-deploy profile (infra/IAM.md):
#   scripts/deploy-gateway.sh plan     <gateway-repo> <target-full-sha> <branch>   reads only
#   scripts/deploy-gateway.sh deploy   <gateway-repo> <target-full-sha> <branch>
#   scripts/deploy-gateway.sh rollback <version>
# There is one gateway: staging and production sites both call it, so a deploy is a production
# change. Order: test and package the commit (nothing live changes), publish the running function
# as a numbered version (the rollback point), then settings the new code needs and the old code
# ignores, then the code, then the layer only the old code needed. Stops at the first failure.
# After a failed deploy, run the rollback line it printed. Secrets pass through files in a private
# scratch directory that is removed on exit; no value is ever printed.
set -euo pipefail
umask 077
usage='usage: deploy-gateway.sh plan|deploy <gateway-repo> <target-full-sha> <branch> | rollback <version>'
mode=${1:?$usage}
profile=${GATEWAY_PROFILE:-amazon-gateway-deploy}
region=us-west-2
fn=AmazonStudiosIndeeTV
url=${GATEWAY_URL:-https://indeetv-watch.amazonmgmstudiosawards.com}
site=${GATEWAY_SITE:-https://amazonmgmstudiosawards.com}   # an origin the gateway must allow
want_timeout=25
want_memory=256
AWS=${AWS_BIN:-aws}     # AWS_BIN, CURL_BIN, SMOKE_PAUSE: test fixtures only
CURL=${CURL_BIN:-curl}
pause=${SMOKE_PAUSE:-3}

die() { echo "ABORT: $*" >&2; exit 1; }
L() { local sub=$1; shift; "$AWS" lambda "$sub" --profile "$profile" --region "$region" --function-name "$fn" "$@"; }
settled() { "$AWS" lambda wait function-updated --profile "$profile" --region "$region" --function-name "$fn"; }
# One line of settings, values never included: runtime handler timeout memory code-hash env-names
# shellcheck disable=SC2016  # backticks below are JMESPath literals, not shell
settings() {
  L get-function-configuration "$@" --output text --query \
    '[Runtime,Handler,to_string(Timeout),to_string(MemorySize),CodeSha256,join(`,`,sort(keys(Environment.Variables||`{}`)))||`none`]'
}
layers() { L get-function-configuration "$@" --output text --query 'Layers[].Arn'; }
has_env() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

work=$(mktemp -d "${TMPDIR:-/tmp}/gateway-deploy.XXXXXX")
trap 'rm -rf "$work"' EXIT

# POST an empty body as a site's browser would and print the HTTP status. The answer lands in
# $work/smoke.json and its headers in $work/smoke.headers.
probe() {
  "$CURL" -s -o "$work/smoke.json" -D "$work/smoke.headers" -w '%{http_code}' --max-time 20 -X POST "$url/" \
    -H 'Content-Type: application/json' -H "Origin: $site" -d '{}'
}
# The function answers without calling upstream: an empty body is a 400 from either code line.
# $1, when given, is text only the new code sends, which proves the new code is the one live.
# The answer must also carry a cross-origin header, or browsers on the sites cannot read it. The
# new code sends none itself: the gateway's CORS settings add it.
smoke() {
  local code=''
  for _ in 1 2 3 4 5; do
    code=$(probe) || code=000
    if [ "$code" = 400 ] && { [ -z "${1:-}" ] || grep -q "$1" "$work/smoke.json"; } \
      && grep -qi '^access-control-allow-origin:' "$work/smoke.headers"; then
      echo "smoke ok: POST {} answered 400 with a cross-origin header"; return 0
    fi
    sleep "$pause"
  done
  echo "smoke FAILED: POST {} answered $code, cross-origin header: $(grep -ci '^access-control-allow-origin:' "$work/smoke.headers" 2>/dev/null || true)"; return 1
}

# The old package keeps the upstream URL and key in a .env file. Copy both into the function's own
# environment, merged over what is already set.
move_key_to_env() {
  local loc
  loc=$(L get-function --query 'Code.Location' --output text)
  "$CURL" -fsS -o "$work/old.zip" "$loc" || die "cannot download the running package"
  unzip -p "$work/old.zip" .env > "$work/old.env" 2>/dev/null \
    || die "the running package has no .env; set API_URL and API_KEY on the function by hand"
  # shellcheck disable=SC2016
  L get-function-configuration --output json --query 'Environment.Variables||`{}`' > "$work/env-now.json"
  python3 -I - "$work/old.env" "$work/env-now.json" "$work/env-new.json" <<'PY' || die "the running package's .env lacks API_URL or API_KEY"
import json, re, sys
found = {}
for line in open(sys.argv[1], encoding="utf-8"):
    match = re.match(r"\s*(API_URL|API_KEY)\s*=\s*(.*?)\s*$", line)
    if match:
        found[match.group(1)] = match.group(2).strip("\"'")
if not found.get("API_URL") or not found.get("API_KEY"):
    sys.exit(1)
merged = {**json.load(open(sys.argv[2], encoding="utf-8")), **found}
json.dump({"Variables": merged}, open(sys.argv[3], "w", encoding="utf-8"))
PY
  L update-function-configuration --environment "file://$work/env-new.json" --output text --query 'LastUpdateStatus' >/dev/null
  settled
  echo "moved API_URL and API_KEY from the package into the function's environment"
}

case "$mode" in
plan|deploy)
  repo=${2:?$usage}; target=${3:?$usage}; branch=${4:?$usage}
  [ ${#target} -eq 40 ] || die "give the full 40-character target SHA"
  git -C "$repo" fetch -q origin "$branch"
  [ "$(git -C "$repo" rev-parse FETCH_HEAD)" = "$target" ] \
    || die "origin/$branch is $(git -C "$repo" rev-parse FETCH_HEAD), not the reviewed target"
  mkdir "$work/src"
  # The function's code is the repo's function/ directory; only that subtree is tested and shipped.
  git -C "$repo" archive "$target:function" | tar -x -C "$work/src"
  ( cd "$work/src" && node --test ) > "$work/test.log" 2>&1 || { tail -n 25 "$work/test.log"; die "tests failed at $target; nothing was changed"; }
  git -C "$repo" archive --format=zip -o "$work/function.zip" "$target:function" index.js gateway.js
  new_hash=$(openssl dgst -sha256 -binary "$work/function.zip" | openssl base64)
  echo "target  $target ($branch), tests pass, package hash $new_hash"

  IFS=$'\t' read -r runtime handler timeout memory live_hash env_names < <(settings) || true
  [ -n "${env_names:-}" ] || die "cannot read the function's settings; check the profile"
  live_layers=$(layers)
  echo "running $runtime $handler timeout=${timeout}s memory=${memory}MB env=[$env_names] layers=[$live_layers] hash $live_hash"
  [ "$handler" = index.handler ] || die "handler is $handler, not index.handler"
  steps=()
  if ! has_env "$env_names" API_KEY || ! has_env "$env_names" API_URL; then steps+=(env); fi
  if [ "$timeout" != "$want_timeout" ] || [ "$memory" != "$want_memory" ]; then steps+=(limits); fi
  [ "$live_hash" = "$new_hash" ] || steps+=(code)
  [ "$live_layers" = None ] || [ -z "$live_layers" ] || steps+=(layers)
  echo "steps   ${steps[*]:-none: the function already matches the target}"
  [ "$mode" = plan ] && { echo "plan only; nothing was changed"; exit 0; }
  [ ${#steps[@]} -gt 0 ] || exit 0

  before=$(L publish-version --description "before ${target:0:12}" --output text --query 'Version')
  echo "rollback point: version $before"
  echo "if a step below fails, run: scripts/deploy-gateway.sh rollback $before"
  for step in "${steps[@]}"; do
    case "$step" in
    env) move_key_to_env ;;
    limits)
      L update-function-configuration --timeout "$want_timeout" --memory-size "$want_memory" --output text --query 'LastUpdateStatus' >/dev/null
      settled; echo "set timeout ${want_timeout}s, memory ${want_memory}MB" ;;
    code)
      sent_hash=$(L update-function-code --zip-file "fileb://$work/function.zip" --output text --query 'CodeSha256')
      settled
      [ "$sent_hash" = "$new_hash" ] || die "the function reports hash $sent_hash, not $new_hash; run: scripts/deploy-gateway.sh rollback $before"
      echo "code is live" ;;
    layers)
      L update-function-configuration --layers '[]' --output text --query 'LastUpdateStatus' >/dev/null
      settled; echo "removed the layer the old code needed" ;;
    esac
  done
  smoke 'Missing or invalid clientId' || die "run: scripts/deploy-gateway.sh rollback $before"
  after=$(L publish-version --description "$target" --output text --query 'Version')
  echo "DONE: $target is live as version $after. Rollback point: version $before."
  echo "Next: the driver plays a title through Watch Now with a real access code."
  ;;
rollback)
  version=${2:?$usage}
  case "$version" in ''|*[!0-9]*) die "give a published version number" ;; esac
  IFS=$'\t' read -r runtime handler timeout memory old_hash env_names < <(settings --qualifier "$version") || true
  [ -n "${env_names:-}" ] || die "cannot read version $version; nothing was changed"
  old_layers=$(layers --qualifier "$version")
  echo "version $version: $runtime $handler timeout=${timeout}s memory=${memory}MB layers=[$old_layers] hash $old_hash"
  loc=$(L get-function --qualifier "$version" --query 'Code.Location' --output text)
  "$CURL" -fsS -o "$work/old.zip" "$loc" || die "cannot download version $version; nothing was changed"
  # Settings first: that version's code needs its layer back before it runs again. The current
  # code ignores a layer, and environment values stay as they are: both code lines read them.
  layer_args=('[]')
  if [ "$old_layers" != None ] && [ -n "$old_layers" ]; then read -r -a layer_args <<< "$old_layers"; fi
  L update-function-configuration --runtime "$runtime" --handler "$handler" --timeout "$timeout" --memory-size "$memory" \
    --layers "${layer_args[@]}" --output text --query 'LastUpdateStatus' >/dev/null
  settled
  sent_hash=$(L update-function-code --zip-file "fileb://$work/old.zip" --output text --query 'CodeSha256')
  settled
  [ "$sent_hash" = "$old_hash" ] || die "the function reports hash $sent_hash, not version $version's $old_hash"
  smoke || die "version $version is back but does not answer; check the function in the console"
  echo "DONE: the function runs version $version's code and settings again."
  ;;
*) die "$usage" ;;
esac
