#!/usr/bin/env bash
# Rotate one site's managed-database login without taking the site offline. Run as root on the
# instance:
#   sudo bash /opt/amazon-server/scripts/rotate-db-login.sh <rsvp|ampas|guilds> [--check]
#
# The site's login lives in its own file: RSVP's config/<environment>/secrets.json, or the
# WordPress site's .env. The script reads it and acts by who that login is:
#   - The database's admin (Lightsail's only console-managed user): create or reset the site user
#     <site>_app with SQL, grant it the site's schema only, test it, then point the file at it.
#     The admin keeps working throughout, so the site never loses its database. Change the admin
#     password in the Lightsail console afterwards: no site uses it any more.
#   - <site>_app already: set a new password on it, then write the file straight away. Only
#     connections opened in that moment can fail.
# A WordPress .env also gets a comment above its database lines saying so. The admin login is
# for the console and emergencies only; never put it back in a site file (docs/ENV-DELTAS.md,
# "Database logins").
# --check reports which case applies and changes nothing.
#
# Writes a root-only backup of the file first (it holds the old password: delete it once the
# site checks pass), keeps the file's owner and mode, reloads RSVP's PHP-FPM pool, and prints no
# password. A local database (127.0.0.1) is refused: staging's local logins belong to its root
# MySQL account.
set -Eeuo pipefail

die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

site="${1:-}"
mode="${2:-rotate}"
case "$site" in
  rsvp | ampas | guilds) ;;
  *) die 'usage: rotate-db-login.sh <rsvp|ampas|guilds> [--check]' ;;
esac
case "$mode" in
  rotate | --check) ;;
  *) die "unknown option ${mode}" ;;
esac
[[ ${EUID} -eq 0 ]] || die 'run as root (sudo)'

# The environment, the file and the reload can be overridden for tests.
environment="${ROTATE_ENVIRONMENT:-$(cat /etc/amazon-server.env 2> /dev/null || echo staging)}"
if [[ "$site" == rsvp ]]; then
  file="${ROTATE_SITE_FILE:-/var/www/html/rsvp/admin/application/config/${environment}/secrets.json}"
else
  file="${ROTATE_SITE_FILE:-/var/www/html/amazon-studios-${site}/.env}"
fi
[[ -f "$file" ]] || die "no login file at ${file}"
backup="${file}.before-rotation-$(date -u +%Y%m%dT%H%M%SZ)-$$"
case_file="$(mktemp)"
trap 'rm -f "$case_file"' EXIT

php -d display_errors=stderr -- "$site" "$file" "$backup" "$mode" "${ROTATE_ALLOW_LOCAL:-0}" "$case_file" <<'PHP'
<?php
[, $site, $file, $backup, $mode, $allowLocal, $caseFile] = $argv;
function fail(string $why): void { fwrite(STDERR, "ABORT: {$why}\n"); exit(1); }

// Read the login, and remember how to write one back.
$text = file_get_contents($file);
$isJson = str_ends_with($file, '.json');
if ($isJson) {
    $data = json_decode($text, true);
    if (!is_array($data)) fail("{$file} is not JSON");
    $keys = ['host' => 'db_hostname', 'user' => 'db_username', 'pass' => 'db_password', 'name' => 'db_database'];
    $get = fn ($k) => $data[$keys[$k]] ?? null;
    $port = (int) ($data['db_port'] ?? 3306);
} else {
    $env = [];
    foreach (explode("\n", $text) as $line) {
        if (preg_match('/^\s*([A-Z_]+)\s*=\s*(.*)$/', $line, $m)) {
            $v = trim($m[2]);
            if (strlen($v) >= 2 && ($v[0] === "'" || $v[0] === '"') && substr($v, -1) === $v[0]) $v = substr($v, 1, -1);
            $env[$m[1]] = $v;
        }
    }
    $keys = ['host' => 'DB_HOST', 'user' => 'DB_USER', 'pass' => 'DB_PASSWORD', 'name' => 'DB_NAME'];
    $get = fn ($k) => $env[$keys[$k]] ?? null;
    $port = isset($env['DB_PORT']) && $env['DB_PORT'] !== '' ? (int) $env['DB_PORT'] : 3306;
}
[$host, $user, $pass, $name] = [$get('host'), $get('user'), $get('pass'), $get('name')];
if (!$host || !$user || $pass === null || !$name) fail("{$file} lacks a database host, user, password or name");
if (preg_match('/^(.+):(\d+)$/', $host, $m)) [$host, $port] = [$m[1], (int) $m[2]];
if (in_array($host, ['127.0.0.1', 'localhost', '::1'], true) && $allowLocal !== '1') {
    fail("{$site} uses a local database ({$host}); rotate its login as MySQL root instead");
}

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
try {
    $db = new mysqli($host, $user, $pass, $name, $port);
} catch (mysqli_sql_exception $e) {
    fail("the current login does not connect: " . $e->getMessage());
}
$grants = implode("\n", array_column($db->query('SHOW GRANTS')->fetch_all(), 0));
$isAdmin = (bool) preg_match('/\bCREATE USER\b.* ON \*\.\* /', $grants);
$appUser = "{$site}_app";
$case = $isAdmin ? 'admin' : ($user === $appUser ? 'app' : 'other');
printf("%s: %s, login file %s, current login %s (%s)\n", $site, $host, $file, $user,
    ['admin' => "the database admin: will create or reset {$appUser} and switch to it",
     'app' => "{$appUser}: will set a new password on it",
     'other' => 'neither the admin nor ' . $appUser][$case]);
if ($case === 'other') fail("log in as the admin or {$appUser} to rotate");
file_put_contents($caseFile, $case);
if ($mode === '--check') exit(0);

// The new file, prepared before any database change so the switch is one rename.
$newPass = substr(preg_replace('/[^A-Za-z0-9]/', '', base64_encode(random_bytes(48))), 0, 32);
if ($isJson) {
    $data[$keys['user']] = $appUser;
    $data[$keys['pass']] = $newPass;
    preg_match('/\n([ \t]+)"/', $text, $m);
    $out = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if (isset($m[1]) && $m[1] !== '    ') {
        $out = preg_replace_callback('/^( +)/m', fn ($s) => str_repeat($m[1], intdiv(strlen($s[1]), 4)), $out);
    }
    $out .= str_ends_with($text, "\n") ? "\n" : '';
} else {
    $values = [$keys['user'] => $appUser, $keys['pass'] => $newPass];
    $lines = explode("\n", $text);
    foreach ($lines as $i => $line) {
        if (preg_match('/^(\s*)([A-Z_]+)(\s*=\s*)(.*)$/', $line, $m) && isset($values[$m[2]])) {
            $old = trim($m[4]);
            $q = strlen($old) >= 2 && ($old[0] === "'" || $old[0] === '"') && substr($old, -1) === $old[0] ? $old[0] : '';
            $lines[$i] = $m[1] . $m[2] . $m[3] . $q . $values[$m[2]] . $q;
        }
    }
    // Say which login this is, right above the database lines; replace any earlier copy.
    $note = [
        "# Site login ({$appUser}), rotated with _server scripts/rotate-db-login.sh.",
        '# The admin login from the Lightsail console is not used here; changing it needs no edit to this file.',
    ];
    $lines = array_values(array_filter($lines, fn ($l) => !str_starts_with($l, '# Site login (')
        && !str_starts_with($l, '# The admin login from the Lightsail console')));
    foreach ($lines as $i => $line) {
        if (preg_match('/^\s*DB_[A-Z_]+\s*=/', $line)) {
            array_splice($lines, $i, 0, $note);
            break;
        }
    }
    $out = implode("\n", $lines);
}
$stat = stat($file);
$tmp = tempnam(dirname($file), '.rotate-');
file_put_contents($tmp, $out);
chown($tmp, $stat['uid']);
chgrp($tmp, $stat['gid']);
chmod($tmp, $stat['mode'] & 0777);
if (!copy($file, $backup)) fail("could not write the backup {$backup}");
chmod($backup, 0600);

try {
    if ($isAdmin) {
        $u = $db->real_escape_string($appUser);
        $p = $db->real_escape_string($newPass);
        $s = str_replace('`', '``', $name);
        $db->query("CREATE USER IF NOT EXISTS '{$u}'@'%' IDENTIFIED BY '{$p}'");
        $db->query("ALTER USER '{$u}'@'%' IDENTIFIED BY '{$p}'");
        $db->query("GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, CREATE TEMPORARY TABLES, LOCK TABLES ON `{$s}`.* TO '{$u}'@'%'");
        $check = new mysqli($host, $appUser, $newPass, $name, $port);
        $check->query('SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()');
        $check->close();
    } else {
        $p = $db->real_escape_string($newPass);
        $db->query("ALTER USER CURRENT_USER() IDENTIFIED BY '{$p}'");
    }
} catch (mysqli_sql_exception $e) {
    @unlink($tmp);
    fail('database step failed, login file unchanged: ' . $e->getMessage());
}
rename($tmp, $file);
if (!$isAdmin) {
    $check = new mysqli($host, $appUser, $newPass, $name, $port);
    $check->close();
}
printf("%s: %s now logs in as %s with a new password; backup %s (root, 600)\n", $site, $file, $appUser, $backup);
PHP

[[ "$mode" == --check ]] && exit 0

# RSVP keeps its login per worker, so its pool reloads; WordPress reads .env per request.
if [[ "$site" == rsvp && "${ROTATE_RELOAD:-1}" == 1 ]]; then
  version="$(awk -F= '$1 == "rsvp_version" { print $2 }' /etc/amazon-server.php-sites 2> /dev/null || true)"
  [[ -n "$version" ]] || die "no rsvp_version in /etc/amazon-server.php-sites; reload RSVP's PHP-FPM by hand"
  systemctl reload "php${version}-fpm"
  printf 'rsvp: reloaded php%s-fpm\n' "$version"
fi

cat << EOF
Next:
  1. Check the site: its admin and one page that reads the database (RSVP: one title's RSVP list).
  2. Check the log has no database errors (RSVP: application/logs/log-$(date -u +%F).php).
  3. Delete the backup once the checks pass: rm -f '${backup}'
  4. If the old login was the admin, change its password in the Lightsail console, and keep it
     out of the site file: no site uses it.
EOF
if [[ "$(cat "$case_file")" == admin ]]; then
  printf "Rollback until the admin password changes: cp -p '%s' '%s'%s\n" "$backup" "$file" \
    "$([[ "$site" == rsvp ]] && printf ', then reload PHP-FPM' || true)"
else
  printf 'No rollback from the backup: the old password no longer works. Re-run to set a fresh one.\n'
fi
