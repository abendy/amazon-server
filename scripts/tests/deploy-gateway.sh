#!/usr/bin/env bash
# Checks for scripts/deploy-gateway.sh. Runs the script against a stand-in `aws` and `curl` that
# keep a fake function's state in files, and a throwaway gateway repo. Nothing real is called.
# Covers: plan changes nothing; a first deploy runs its steps in the safe order and prints no
# secret; a repeat deploy is a no-op; a stale target, failing tests, a failed smoke and a missing
# cross-origin header each stop;
# rollback restores settings before code; the scratch directory is always removed.
# Exit status is the number of failed checks.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(dirname "$TESTS_DIR")/deploy-gateway.sh"
FAILURES=0
SECRET='s3cret-key-value-do-not-print'
LAYER='arn:aws:lambda:us-west-2:000000000000:layer:Old-Layer:3'

root=$(mktemp -d "${TMPDIR:-/tmp}/gateway-test.XXXXXX")
trap 'rm -rf "$root"' EXIT
state="$root/state"; bin="$root/bin"; scratch="$root/scratch"
mkdir -p "$state" "$bin" "$scratch"

check() {  # check <description> <command...>
  if "${@:2}"; then echo "ok    $1"; else echo "FAIL  $1"; FAILURES=$((FAILURES + 1)); fi
}

cat > "$bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
s=$STUB_STATE
args="$*"
echo "$args" | sed -E 's#[^ ]*/(gateway-deploy\.)[A-Za-z0-9]+#\1X#g' >> "$s/calls.log"
q=$(echo "$args" | grep -oE -- '--qualifier [0-9]+' | grep -oE '[0-9]+' || true)
if [ -n "$q" ] && [ ! -f "$s/v$q-hash" ]; then echo "stub aws: no version $q" >&2; exit 1; fi
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' nodejs22.x index.handler "$(cat "$s/$1timeout")" "$(cat "$s/$1memory")" "$(cat "$s/$1hash")" "$(cat "$s/$1envnames")"; }
case "$args" in
*"wait function-updated"*) ;;
*get-function-configuration*--qualifier*"Layers[].Arn"*) cat "$s/v$q-layers" ;;
*get-function-configuration*--qualifier*) row "v$q-" ;;
*get-function-configuration*"Layers[].Arn"*) cat "$s/layers" ;;
*get-function-configuration*"output json"*) cat "$s/env.json" ;;
*get-function-configuration*) row "" ;;
*"lambda get-function "*) echo "https://stub.invalid/code.zip?v=${q:-live}" ;;
*publish-version*)
  n=$(($(cat "$s/version") + 1)); echo "$n" > "$s/version"
  for f in timeout memory hash envnames layers live.zip; do cp "$s/$f" "$s/v$n-$f"; done
  echo "$n" ;;
*update-function-code*)
  file=$(echo "$args" | grep -oE 'fileb://[^ ]+' | sed 's#fileb://##')
  cp "$file" "$s/live.zip"
  openssl dgst -sha256 -binary "$file" | openssl base64 > "$s/hash"; cat "$s/hash" ;;
*update-function-configuration*--environment*)
  file=$(echo "$args" | grep -oE 'file://[^ ]+' | sed 's#file://##')
  python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))["Variables"]; json.dump(v,open(sys.argv[2],"w")); open(sys.argv[3],"w").write(",".join(sorted(v)))' "$file" "$s/env.json" "$s/envnames"
  echo Successful ;;
*update-function-configuration*--layers*)
  if [[ "$args" == *"--layers []"* ]]; then echo None > "$s/layers"; else echo "$args" | grep -oE 'arn:aws:lambda:[^ ]+' > "$s/layers"; fi
  if [[ "$args" == *--timeout* ]]; then
    echo "$args" | sed -E 's/.*--timeout ([0-9]+).*/\1/' > "$s/timeout"
    echo "$args" | sed -E 's/.*--memory-size ([0-9]+).*/\1/' > "$s/memory"
  fi
  echo Successful ;;
*update-function-configuration*--timeout*)
  echo "$args" | sed -E 's/.*--timeout ([0-9]+).*/\1/' > "$s/timeout"
  echo "$args" | sed -E 's/.*--memory-size ([0-9]+).*/\1/' > "$s/memory"
  echo Successful ;;
*) echo "stub aws: unexpected call: $args" >&2; exit 9 ;;
esac
STUB

cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
s=$STUB_STATE
out=''; hdr=''; prev=''
for a in "$@"; do [ "$prev" = -o ] && out=$a; [ "$prev" = -D ] && hdr=$a; prev=$a; done
case "$*" in
*code.zip\?v=live*) cp "$s/live.zip" "$out" ;;
*code.zip\?v=*) v=$(echo "$*" | sed -E 's/.*code\.zip\?v=([0-9]+).*/\1/'); cp "$s/v$v-live.zip" "$out" ;;
*) cat "$s/smoke-body" > "$out"; cat "$s/smoke-headers" > "$hdr"; printf '%s' "$(cat "$s/smoke-status")" ;;
esac
STUB
chmod +x "$bin/aws" "$bin/curl"

# A gateway repo with an origin, one passing test, and the two packaged files.
origin="$root/origin.git"; repo="$root/repo"
git init -q --bare "$origin"
git init -q -b develop "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name test
git -C "$repo" config commit.gpgsign false
mkdir "$repo/function"
echo "exports.handler = async () => ({ statusCode: 200 });" > "$repo/function/index.js"
echo "module.exports = {};" > "$repo/function/gateway.js"
printf '%s\n' "require('node:test').test('ok', () => {});" > "$repo/function/index.test.js"
git -C "$repo" add . && git -C "$repo" commit -q -m one
git -C "$repo" remote add origin "$origin" && git -C "$repo" push -q origin develop
target=$(git -C "$repo" rev-parse HEAD)

reset_state() {  # the function as it runs today: old package with a .env, a layer, no env
  rm -f "$state"/*
  ( cd "$root" && printf 'API_URL="https://up.invalid/v2"\nAPI_KEY=%s\n' "$SECRET" > .env \
    && echo old > api.js && zip -q -X "$state/live.zip" .env api.js && rm .env api.js )
  openssl dgst -sha256 -binary "$state/live.zip" | openssl base64 > "$state/hash"
  echo 10 > "$state/timeout"; echo 128 > "$state/memory"; echo none > "$state/envnames"
  echo "$LAYER" > "$state/layers"; echo '{}' > "$state/env.json"; echo 0 > "$state/version"
  echo 400 > "$state/smoke-status"; echo '{"message":"Missing or invalid clientId"}' > "$state/smoke-body"
  printf 'HTTP/2 400\r\naccess-control-allow-origin: https://site.invalid\r\n' > "$state/smoke-headers"
  : > "$state/calls.log"
}
run() {  # run <args...>: output lands in $root/out, exit status in $rc
  rc=0
  STUB_STATE="$state" AWS_BIN="$bin/aws" CURL_BIN="$bin/curl" SMOKE_PAUSE=0 TMPDIR="$scratch" \
    bash "$SCRIPT" "$@" > "$root/out" 2>&1 || rc=$?
}
writes() { grep -cE 'lambda (update-|publish-)' "$state/calls.log" || true; }
order() { grep -oE 'lambda (publish-version|update-function-code|update-function-configuration)( --[a-z-]+ [^ ]+){3} --(environment|timeout|layers|runtime|zip-file|description)' "$state/calls.log" | sed -E 's/lambda ([a-z-]+) .* --([a-z-]+)$/\1:\2/' | tr '\n' ' '; }
# shellcheck disable=SC2329  # called through check
no_scratch() { [ -z "$(ls -A "$scratch")" ]; }

reset_state
run plan "$repo" "$target" develop
check "plan exits 0" [ "$rc" = 0 ]
check "plan writes nothing" [ "$(writes)" = 0 ]
check "plan names every step" grep -q 'steps   env limits code layers' "$root/out"

run deploy "$repo" "$target" develop
check "first deploy exits 0" [ "$rc" = 0 ]
check "steps run in the safe order" [ "$(order)" = "publish-version:description update-function-configuration:environment update-function-configuration:timeout update-function-code:zip-file update-function-configuration:layers publish-version:description " ]
check "the key reached the function's environment" grep -q "$SECRET" "$state/env.json"
check "no secret in the output" bash -c "! grep -q '$SECRET' '$root/out'"
check "no secret in any command line" bash -c "! grep -q '$SECRET' '$state/calls.log'"
check "the layer is gone" [ "$(cat "$state/layers")" = None ]
check "limits are set" [ "$(cat "$state/timeout") $(cat "$state/memory")" = "25 256" ]
check "the scratch directory is removed" no_scratch

: > "$state/calls.log"
sleep 2   # a later run must build the same package, byte for byte
run deploy "$repo" "$target" develop
check "a repeat deploy exits 0" [ "$rc" = 0 ]
check "a repeat deploy writes nothing" [ "$(writes)" = 0 ]

reset_state
run rollback 1
check "rollback of a missing version stops" [ "$rc" != 0 ]
run deploy "$repo" "$target" develop
: > "$state/calls.log"
echo '{"message":"Missing clientId"}' > "$state/smoke-body"
run rollback 1
check "rollback exits 0" [ "$rc" = 0 ]
check "rollback restores settings before code" [ "$(order)" = "update-function-configuration:runtime update-function-code:zip-file " ]
check "rollback puts the layer back" [ "$(cat "$state/layers")" = "$LAYER" ]
check "rollback restores the old limits" [ "$(cat "$state/timeout") $(cat "$state/memory")" = "10 128" ]
check "rollback restores the old package" cmp -s "$state/live.zip" "$state/v1-live.zip"
check "rollback leaves no scratch directory" no_scratch

reset_state
run deploy "$repo" 0000000000000000000000000000000000000000 develop
check "a target that is not the branch tip stops" [ "$rc" != 0 ]
check "a stale target writes nothing" [ "$(writes)" = 0 ]

reset_state
echo 500 > "$state/smoke-status"
run deploy "$repo" "$target" develop
check "a failed smoke exits non-zero" [ "$rc" != 0 ]
check "a failed smoke prints the rollback line" grep -q 'deploy-gateway.sh rollback 1' "$root/out"
check "a failed smoke leaves no scratch directory" no_scratch

reset_state
printf 'HTTP/2 400\r\n' > "$state/smoke-headers"
run deploy "$repo" "$target" develop
check "a missing cross-origin header fails the smoke" [ "$rc" != 0 ]
check "a missing cross-origin header prints the rollback line" grep -q 'deploy-gateway.sh rollback 1' "$root/out"

printf '%s\n' "require('node:test').test('bad', () => { throw new Error('x'); });" > "$repo/function/index.test.js"
git -C "$repo" commit -q -am two && git -C "$repo" push -q origin develop
reset_state
run deploy "$repo" "$(git -C "$repo" rev-parse HEAD)" develop
check "failing tests stop the deploy" [ "$rc" != 0 ]
check "failing tests write nothing" [ "$(writes)" = 0 ]

echo "failed checks: $FAILURES"
exit "$FAILURES"
