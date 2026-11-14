#!/usr/bin/env bash
# Deploy one WordPress site to one exact, reviewed commit. Run on the host as ubuntu (uses sudo):
#   ssh <host> 'bash -s -- <ampas|guilds> <target-full-sha> <master|develop> [repair]' < scripts/deploy-wp.sh   (from this repo)
# Order: checks, Composer download into a scratch copy (nothing live changes), then a short swap
# (git, Composer from the warm cache, ownership, database upgrade). Stops at the first failure.
# Re-runnable, and the recovery path: nothing before the swap loads WordPress, so a re-run works
# even when a failed Composer run left web/wp empty. At the target it skips the merge.
# After ANY failed run, re-run with `repair`: it force-reinstalls every installed package, core
# included, because Composer trusts its metadata and won't restore files it thinks are installed.
# Without `repair`, core is reinstalled automatically when a bootstrap file is missing.
set -euo pipefail
site=${1:?usage: deploy-wp.sh <ampas|guilds> <target-full-sha> <master|develop>}
target=${2:?give the full target SHA}
branch=${3:?give the branch the target is on}
mode=${4:-}
case "$mode" in ""|repair) ;; *) echo "ABORT: fourth argument must be 'repair' or nothing"; exit 1 ;; esac
w=${WP_ROOT:-/var/www/html/amazon-studios-$site}   # WP_ROOT: test fixtures only
core_files=(wp-load.php wp-settings.php wp-blog-header.php wp-includes/version.php wp-includes/load.php
  wp-includes/default-constants.php wp-includes/plugin.php wp-admin/includes/upgrade.php)
G() { git -C "$w" "$@"; }
die() { echo "ABORT: $*"; exit 1; }
composer_root() { sudo -n env HOME=/root COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 /usr/local/bin/composer "$@"; }
db_version() {  # read wp_options.db_version over SQL with the site's .env; never loads WordPress
  sudo -n -u www-data php -r '
    $env = [];
    foreach (file($argv[1] . "/.env", FILE_IGNORE_NEW_LINES) as $l) { if (preg_match("/^([A-Z_]+)=(.*)$/", $l, $m)) $env[$m[1]] = trim($m[2], "\"'"'"' "); }
    $db = @new mysqli($env["DB_HOST"], $env["DB_USER"], $env["DB_PASSWORD"], $env["DB_NAME"], (int)($env["DB_PORT"] ?? 3306));
    if ($db->connect_errno) { fwrite(STDERR, "db connect failed\n"); exit(1); }
    $p = $env["DB_PREFIX"] ?? "wp_";
    $r = $db->query("SELECT option_value FROM {$p}options WHERE option_name = \"db_version\"");
    if (!$r || !($row = $r->fetch_row())) { fwrite(STDERR, "db_version not found\n"); exit(1); }
    echo $row[0], "\n";' "$w"
}
core_missing() {  # print the first missing bootstrap file of web/wp, if any
  local f; for f in "${core_files[@]}"; do [ -f "$w/web/wp/$f" ] || { echo "$f"; return 0; }; done; return 1
}
code_db_version() { grep -oE '^\$wp_db_version = [0-9]+' "$w/web/wp/wp-includes/version.php" | grep -oE '[0-9]+$'; }

[ ${#target} -eq 40 ] || die "give the full 40-character target SHA"
[ -f "$w/auth.json" ] || die "auth.json missing; Composer cannot fetch ACF Pro"
[ "$(G status --porcelain --untracked-files=no | wc -l)" = 0 ] || die "checkout has local changes; nothing was changed"
start=$(G rev-parse HEAD)
echo "start  $start"
echo "target $target"
db_before=$(db_version) || die "cannot read db_version over SQL"
if missing=$(core_missing); then
  echo "RECOVERY: web/wp is incomplete (missing $missing); core will be reinstalled (db_version $db_before)"
else
  echo "before: db_version $db_before, core $(grep -oE "'[0-9.]+'" "$w/web/wp/wp-includes/version.php" | head -1)"
fi
[ "$mode" = repair ] && echo "REPAIR: every installed package will be force-reinstalled"
if [ "$start" != "$target" ]; then
  G fetch -q origin "$branch"
  [ "$(G rev-parse FETCH_HEAD)" = "$target" ] || die "origin/$branch is $(G rev-parse FETCH_HEAD), not the reviewed target"
  G merge-base --is-ancestor "$start" "$target" || die "target does not descend from the deployed commit"
fi

# Download everything the target needs into a scratch copy, so auth or network failures stop here.
scratch=$(mktemp -d /tmp/wp-predownload.XXXXXX)
G show "$target:composer.json" > "$scratch/composer.json"
G show "$target:composer.lock" > "$scratch/composer.lock"
sudo -n cp "$w/auth.json" "$scratch/auth.json"
( cd "$scratch" && composer_root install --no-dev --download-only --no-scripts --no-plugins --no-progress ) \
  || { sudo -n rm -rf "$scratch"; die "pre-download failed; the live site is unchanged"; }
sudo -n rm -rf "$scratch"
echo "pre-download ok; rollback point: $start (db_version $db_before)"

# Swap. Seconds of exposure: keep this inside the maintenance window.
if [ "$start" != "$target" ]; then
  sudo -n git -c safe.directory="$w" -C "$w" merge --ff-only -q "$target" || die "fast-forward failed; check git status before retrying"
fi
if ! ( cd "$w" && composer_root install --no-dev --no-interaction --no-progress ); then
  echo "ABORT: composer install failed. web/wp may be incomplete. Re-run the same command with 'repair':"
  echo "it reads the database over SQL, so it works without WordPress core. If that fails, see docs/SITE-DEPLOY.md, 'Rollback'."
  exit 1
fi
# Composer trusts its own metadata, so half-removed files still read as installed. Force them back.
if [ "$mode" = repair ]; then
  # Skip packages whose install path holds files tracked in git (AMPAS commits wp-acf-unique_id,
  # #92): git owns those, and a reinstall would overwrite them.
  installed=()
  while read -r name path; do
    [ -n "$name" ] || continue
    rel=${path#"$w"/}
    if [ "$rel" != "$path" ] && [ -n "$(G ls-files -- "$rel" | head -1)" ]; then echo "repair: skipping $name (tracked in git at $rel)"; continue; fi
    installed+=("$name")
  done < <(cd "$w" && composer_root show --no-dev --path 2>/dev/null)
  [ "${#installed[@]}" -gt 0 ] || die "repair: cannot list installed packages"
  echo "repair: reinstalling ${#installed[@]} packages"
  ( cd "$w" && composer_root reinstall --no-interaction --no-progress "${installed[@]}" ) \
    || die "repair: composer reinstall failed; see docs/SITE-DEPLOY.md, 'Rollback'"
elif missing=$(core_missing); then
  echo "core incomplete after install (missing $missing): reinstalling roots/wordpress-no-content"
  ( cd "$w" && composer_root reinstall --no-interaction --no-progress roots/wordpress-no-content ) \
    || die "composer reinstall of WordPress core failed; re-run with repair, or see docs/SITE-DEPLOY.md, 'Rollback'"
fi
sudo -n find "$w" -path "$w/web/app/uploads" -prune -o -user root -exec chown ubuntu:ubuntu {} +
[ "$(G rev-parse HEAD)" = "$target" ] || die "HEAD is $(G rev-parse HEAD)"
[ "$(G status --porcelain --untracked-files=no | wc -l)" = 0 ] || die "checkout not clean after deploy"
if missing=$(core_missing); then die "web/wp/$missing still missing after composer; re-run with repair"; fi
[ -z "$(sudo -n find "$w" -path "$w/web/app/uploads" -prune -o -user root -print -quit)" ] || die "root-owned files remain"
sudo -n -u www-data php -r '
  define("WP_INSTALLING", true); chdir($argv[1]); require "web/wp/wp-load.php";
  require_once ABSPATH . "wp-admin/includes/upgrade.php"; wp_upgrade(); wp_cache_flush();' "$w"
db_after=$(db_version) || die "cannot read db_version after the upgrade"
want=$(code_db_version) || die "cannot read wp_db_version from core"
[ "$db_after" = "$want" ] || die "db_version $db_after does not match core's $want"
echo "verified $target: core $(grep -oE "'[0-9.]+'" "$w/web/wp/wp-includes/version.php" | head -1), db_version $db_before -> $db_after"
echo "rollback point: $start (db_version $db_before)"
