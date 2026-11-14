#!/usr/bin/env bash
# Deploy RSVP to one exact, reviewed commit. Run on the host as ubuntu (uses sudo):
#   ssh <host> 'bash -s -- <target-full-sha> <master|develop> [applied-migration-dir ...]' < scripts/deploy-rsvp.sh   (from this repo)
# A range that adds files under scripts/migrations/ is refused until each of its migration
# directories is applied by hand (rsvp docs/DEPLOYMENT.md) and named after the branch, exactly.
# Stops at the first failure and prints what to do. Never resets a checkout that had local changes.
# Re-runnable: at the target it skips the merge but still repairs ownership and verifies, which is
# the recovery path after the documented root reset.
set -euo pipefail
target=${1:?usage: deploy-rsvp.sh <target-full-sha> <master|develop>}
branch=${2:?give the branch the target is on}
shift 2
applied=$(printf '%s\n' "$@" | sed '/^$/d' | sort -u)   # migration directories applied by hand
r=/var/www/html/rsvp
G() { git -c safe.directory="$r" -C "$r" "$@"; }          # as ubuntu: owns .git and the github-rsvp SSH alias
GR() { sudo -n git -c safe.directory="$r" -C "$r" "$@"; } # as root: can replace files in the www-data-owned root
die() { echo "ABORT: $*"; exit 1; }

[ ${#target} -eq 40 ] || die "give the full 40-character target SHA"
if [ "$(G status --porcelain --untracked-files=no | wc -l)" != 0 ]; then
  echo "ABORT: checkout has local changes; nothing was changed."
  echo "If a previous run of this script failed part-way on a clean checkout, finish it with:"
  echo "  sudo git -c safe.directory=$r -C $r reset --hard $target"
  echo "then re-run this script; at the target it repairs ownership and verifies."
  exit 1
fi
start=$(G rev-parse HEAD)
echo "start  $start"
echo "target $target"

if [ "$start" = "$target" ]; then
  echo "at target: skipping the merge; repairing ownership and verifying"
else
  G fetch -q origin "$branch"
  [ "$(G rev-parse FETCH_HEAD)" = "$target" ] || die "origin/$branch is $(G rev-parse FETCH_HEAD), not the reviewed target"
  G merge-base --is-ancestor "$start" "$target" || die "target does not descend from the deployed commit"
  pending=$(G diff --name-only "$start" "$target" -- scripts/migrations | cut -d/ -f3 | sed '/^$/d' | sort -u)
  if [ -n "$pending" ] && [ "$pending" != "$applied" ]; then
    die "migrations in this range: $(echo $pending). Apply each by hand first (rsvp docs/DEPLOYMENT.md), then name exactly those directories after the branch. Named: $(echo ${applied:-none})"
  fi
  [ -z "$pending" ] || echo "migrations applied by hand, as named: $(echo $pending)"
  echo "rollback point: $start"
  if ! GR merge --ff-only -q "$target"; then
    echo "ABORT: fast-forward failed part-way. The checkout was clean before this run, so finish with:"
    echo "  sudo git -c safe.directory=$r -C $r reset --hard $target"
    echo "then re-run this script to repair ownership and verify."
    exit 1
  fi
fi

sudo -n chown -R ubuntu:ubuntu "$r/.git"
sudo -n find "$r" -user root -exec chown ubuntu:ubuntu {} +
[ "$(G rev-parse HEAD)" = "$target" ] || die "HEAD is $(G rev-parse HEAD), not the target"
[ "$(G status --porcelain --untracked-files=no | wc -l)" = 0 ] || die "checkout not clean"
[ -z "$(sudo -n find "$r" -user root -print -quit)" ] || die "root-owned files remain"
sudo -n -u www-data test -w "$r/admin/application/logs" || die "www-data cannot write admin/application/logs"
echo "verified $target (rollback point $start)"
