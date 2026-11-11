# Environment deltas

This table is the complete replacement list for the shared nginx tree. The checked-in values are
the local harness values. R4 supplies the staging and production values when it provisions the
co-located instance. Values not listed here are byte-shared.

The repository contains no certificates, certificate keys, `.htpasswd` hashes, passwords, or other
credentials. The paths below describe provisioner-owned locations only.

## Site and environment values

| Site | Environment | `server_name` | Listeners and TLS | Docroot | `HTTP_CI_ENV` | FPM upstream | Auth | Access / error logs |
|---|---|---|---|---|---|---|---|---|
| RSVP | local | `localhost 127.0.0.1 rsvp.local` (rsvp.local for tailnet viewing) | HTTP `80`, default server | `/var/www/html` | `local` | `fpm:9000` | Off | `/var/log/nginx/rsvp-access.log` / `/var/log/nginx/rsvp-error.log` |
| RSVP | staging | `stg.rsvp.amazonmgmstudiosawards.com` | HTTP `80` redirects to TLS `443`; certificate is provisioner-owned | provisioner-owned RSVP docroot | `staging` | provisioner-owned RSVP FPM pool | `$rsvp_auth` defaults to `Staging` for non-allow-listed embed origins; `/etc/nginx/.htpasswd` applies only to `/rsvp/consideramazon/*` | provisioner-owned RSVP log root |
| RSVP | production | `rsvp.amazonmgmstudiosawards.com` | HTTP `80` redirects to TLS `443`; certificate is provisioner-owned | provisioner-owned RSVP docroot | `production` | provisioner-owned RSVP FPM pool | Off; no `.htpasswd` gate in the production embed block | provisioner-owned RSVP log root |
| AMPAS | local | `ampas.local` | HTTP `80` | `/var/www/html/amazon-studios-ampas/web` | Not applicable | `ampas-fpm:9000` | Off | `/var/log/nginx/ampas-access.log` / `/var/log/nginx/ampas-error.log` |
| AMPAS | staging | `stg.amazonmgmstudiosawards.com` | HTTP `80` redirects to TLS `443`; certificate is provisioner-owned | `/var/www/html/amazon-studios-ampas/web` | Not applicable | provisioner-owned AMPAS WP pool on `AMPAS_PHP_VERSION` | Off | provisioner-owned AMPAS log root |
| AMPAS | production | `amazonmgmstudiosawards.com www.amazonmgmstudiosawards.com` | HTTP `80` redirects to TLS `443`; certificate is provisioner-owned | `/var/www/html/amazon-studios-ampas/web` | Not applicable | provisioner-owned AMPAS WP pool on `AMPAS_PHP_VERSION` | Off | provisioner-owned AMPAS log root |
| Guilds | local | `guilds.local` | HTTP `80` | `/var/www/html/amazon-studios-guilds/web` | Not applicable | `guilds-fpm:9000` | Off | `/var/log/nginx/guilds-access.log` / `/var/log/nginx/guilds-error.log` |
| Guilds | staging | `stg.amazonmgmstudiosguilds.com` | HTTP `80` redirects to TLS `443`; certificate is provisioner-owned | `/var/www/html/amazon-studios-guilds/web` | Not applicable | provisioner-owned Guilds WP pool on `GUILDS_PHP_VERSION` | Off | provisioner-owned Guilds log root |
| Guilds | production | `_` in the current coming-soon block; final host binding is not present in the deployed reference | HTTP `80` coming-soon placeholder until R4 supplies the TLS listener | `/var/www/html/amazon-studios-guilds/web` | Not applicable | provisioner-owned Guilds WP pool on `GUILDS_PHP_VERSION` | Off | provisioner-owned Guilds log root |

## Site logs, rotation, and media upload limits

Provisioner-owned (`infra/cloud-init.sh`), driver-ratified 2026-09-10 after production filled
its disk with debug-level nginx error logs.

| Environment | WordPress `error_log` level | RSVP `error_log` level | `/var/log/nginx/*/*.log` rotation |
|---|---|---|---|
| local | shared tree (`warn`) | shared tree (`warn`) | none (docker) |
| staging | `debug` | `warn` | daily or at 1G, keep 3, compressed |
| production | `warn` | `warn` | daily or at 4G, keep 14, compressed |

Upload limits are the same on every provisioned instance: PHP-FPM pools `upload_max_filesize`
and `post_max_size` 512M, `max_execution_time` and `max_input_time` 600s; nginx
`client_max_body_size` 600m, `client_body_timeout` 300s, `fastcgi_read_timeout` 600s for
WordPress. Trailers upload through WP Media, so these must hold on every re-provision.

## Scheduled jobs

Converge installs the RSVP reminder and confirmation crons on production only:
`install_reminder_cron` and `install_confirmation_cron` in
[`infra/cloud-init.sh`](../infra/cloud-init.sh) refuse any other environment
([`infra/README.md`](../infra/README.md), "RSVP reminders (production only)" and "RSVP
confirmation retries (production only)"). Neither removes a cron file it did not install, so a
hand-made one would survive; staging has none.

| Environment | RSVP reminder emails (hourly) | RSVP confirmation retries (every 15 minutes) |
|---|---|---|
| local | none; run `run_reminder.docker.sh` by hand, and its mail lands in Mailpit | none; confirmations send inside the RSVP request |
| staging | none; reminders stay off | none |
| production | `/etc/cron.d/amazon-rsvp-reminders` | `/etc/cron.d/amazon-rsvp-confirmations` |

## Outgoing mail

Local mail never leaves the Docker host. Staging and production send through SES, configured in
each site repository, not in this tree.

| Environment | RSVP and WordPress SMTP | Mail viewer |
|---|---|---|
| local | `mailpit:1025` on `amazon-local`, no login, no TLS; not published on the host | `http://mailpit.local`, `http://mailpit.dev.amazonmgmstudiosawards.com`, or host port `8025` |
| staging | SES; RSVP's login in its secrets file (below) | none |
| production | SES; RSVP's login in its secrets file (below) | none |

`nginx/server_blocks/mailpit.conf` is local only. It ships with the tree, but on an instance its
names have no DNS record and its upstream never resolves, so it serves nothing.

## RSVP secrets file

On staging and production, RSVP reads its SES SMTP login and its database login from an untracked
file in the checkout:

```text
/var/www/html/rsvp/admin/application/config/<environment>/secrets.json   # staging or production
```

Git ignores it, and provisioning does not write it: the driver does. PHP-FPM and the reminder cron
both run as `www-data` and both read it. `includes/security.conf` denies `config/`, so nginx never
serves it. It holds one JSON object with a string value for each of `smtp_user`, `smtp_pass`,
`db_hostname`, `db_username`, `db_password` and `db_database`. RSVP decodes it as JSON and never
runs it. rsvp's `docs/DEPLOYMENT.md` ("Secrets File") says which code reads each key.

Any failure logs one fixed line naming the file and the keys it could not supply, in
`/var/www/html/rsvp/admin/application/logs/log-<date>.php`. That covers a missing or unreadable
file, invalid JSON, a top level that is not an object, and a missing, empty or non-string value.
The line never holds a value, the file's content or the JSON decoder's message. A missing database
key stops each request with a blank 500. A missing mail key leaves the login empty, so each send
fails and is logged.

### Before the pull that brings the loader

Do this on staging, then production, before the first pull that brings
`admin/application/helpers/secrets_helper.php`. Without the file, that pull takes the site down.
After a fetch, this exits 0 when the incoming branch carries the loader:

```bash
git -C /var/www/html/rsvp cat-file -e origin/<branch>:admin/application/helpers/secrets_helper.php
```

1. Create the file, owned by root and readable by `www-data` only:

   ```bash
   sudo install -o root -g www-data -m 0640 /dev/null /var/www/html/rsvp/admin/application/config/<environment>/secrets.json
   sudoedit /var/www/html/rsvp/admin/application/config/<environment>/secrets.json
   ```

2. Fill in every value. Start the SES login with the new credential (rotation, below). Copy the
   database login from that environment's tracked `database.php` as it is before the pull:

   ```json
   {
     "smtp_user": "",
     "smtp_pass": "",
     "db_hostname": "",
     "db_username": "",
     "db_password": "",
     "db_database": ""
   }
   ```

3. Check it as `www-data`. It reads and decodes the JSON the way RSVP does and never runs it. It
   prints each key name with `set` or `MISSING`, or one fixed `ERROR` line and exit 1 when the file
   is missing, unreadable or not a JSON object. It never prints a value, the file's content or the
   decoder's message. A file that is just `[]` passes the object test and shows every key
   `MISSING`, so treat any `MISSING` as a failed check.

   ```bash
   sudo -u www-data php -r '$f = "/var/www/html/rsvp/admin/application/config/<environment>/secrets.json"; set_error_handler(function () { return true; }); $j = file_get_contents($f); restore_error_handler(); try { $s = is_string($j) ? json_decode($j, true, 4, JSON_THROW_ON_ERROR) : null; } catch (JsonException $e) { $s = null; } if (!is_array($s) || ($s !== array() && array_is_list($s))) { echo "ERROR: ", $f, " is missing, unreadable or not a JSON object\n"; exit(1); } foreach (array("smtp_user", "smtp_pass", "db_hostname", "db_username", "db_password", "db_database") as $k) { echo $k, ": ", (isset($s[$k]) && is_string($s[$k]) && $s[$k] !== "" ? "set" : "MISSING"), "\n"; }'
   ```

4. Pull as rsvp's `docs/DEPLOYMENT.md` says, then run its staging check.
5. Confirm there are no `secrets:` lines in the app log:

   ```bash
   sudo grep -n 'secrets:' /var/www/html/rsvp/admin/application/logs/log-$(date +%F).php
   ```

### Rotating the SES SMTP login

1. Create a new SES SMTP credential in AWS. Keep the old one active.
2. Put the new `smtp_user` and `smtp_pass` in the staging file, then the production file.
3. Deploy, if the loader is not live yet (above). Once it is live, the next request reads the file.
   If a send still uses the old login, reload RSVP's PHP-FPM:
   `sudo systemctl reload php<version>-fpm`, the version in the name of
   `/run/php/php<version>-fpm-rsvp.sock`.
4. Check one send in each environment, such as a test RSVP from an address that receives mail there.
   Look for its success, and for no `secrets:` or SMTP error lines in the app log.
5. Revoke the old credential in AWS.

### Rotating the database password

1. Create the new login on the database server, keeping the old one working. Where the database
   has only one admin login and changing it ends the old password at once, do steps 1 and 2 back to
   back: requests fail between them.
2. Put the new `db_username` and `db_password` in the file, and reload PHP-FPM as in the SES steps.
3. Check: log in to the admin, open one title's RSVP list, and confirm no `secrets:` or database
   error lines in the app log. The reminder cron reads the same file on its next run.
4. Remove the old login on the database server.

## Local database publishing

The site Compose files publish MySQL on `0.0.0.0` (same as today's RSVP `3307`). There is no
bind-IP setting. Tailscale and firewall state are driver-owned machine settings. WordPress
accepts `host:port` in `DB_HOST`; RSVP's mysqli driver does not, so the laptop sets `DB_HOST`
and `DB_PORT` separately.

| Site | Environment | Bind | Published MySQL port | Laptop values |
|---|---|---|---:|---|
| RSVP | local | `0.0.0.0` | `3307` | `DB_HOST=nigiri-san.taila71bd7.ts.net` and `DB_PORT=3307` |
| AMPAS | local | `0.0.0.0` | `3308` | `DB_HOST=nigiri-san.taila71bd7.ts.net:3308` |
| Guilds | local | `0.0.0.0` | `3309` | `DB_HOST=nigiri-san.taila71bd7.ts.net:3309` |

`HTTP_CI_ENV` is sent only to RSVP PHP-FPM. The shared line uses the `local` value; R4
replaces it with `staging` or `production` in the environment delta. The deployed production
parameter file supplies `production`, and the application also falls back to `production` when the
key is absent; neither behavior is changed here.

The shared base sets `server_tokens off`. The RSVP local server block overrides that one value to
`on` so its native redirect body stays byte-identical to the RS-04 baseline; staging and production
retain `off`, and the AMPAS/Guilds blocks retain `off` in every environment.

The staging auth behavior comes from the deployed `rsvp/maps.conf` and `rsvp/embed-routing.conf`:
the two `consideramazon` origins bypass basic auth, while other origins use the `Staging` realm.
The shared tree carries the map and the `.htpasswd` path, never the file contents.

## Site-specific shared-policy values

These values differ by site in the shared server blocks and are consumed by the shared includes.
The RSVP row below describes the legacy `/rsvp/(css|js)` rule. The deployed RSVP generic CSS/JS
rule has different values and is listed as an environment delta below.

| Site | `X-Frame-Options` | General asset expiry | CSS/JS expiry | CSS/JS cache headers |
|---|---|---:|---:|---|
| RSVP | none | `1h` | `-1` | `no-store, no-cache, must-revalidate` |
| AMPAS | none | `1y` | `-1` | `no-store, no-cache, must-revalidate` plus `Pragma: no-cache` |
| Guilds | `SAMEORIGIN` | `1y` | `1y` | none beyond `expires` |

## Environment-specific routing and cache deltas

These rows are part of the complete replacement list. They record differences that the local
must-serve matrix cannot observe, or values that R4 must ratify before provisioning.

| Site | Environment | Surface | Shared-tree behavior | Deployed reference or R4 action |
|---|---|---|---|---|
| RSVP | local | Consider Amazon embed | Inherits server-level `Access-Control-Allow-Origin *`, methods `POST, GET, OPTIONS`, and `Content-Type`; no location-level `OPTIONS 204` or no-cache rule. | `_server/nginx/nginx.conf:38-51` and `_server/nginx/server_blocks/rsvp.conf:27-29,42-60`; retained for RS-04 local parity. |
| RSVP | staging | Consider Amazon embed | R4 must add in-location CORS with origin `*`, methods `GET, OPTIONS`, and `Content-Type`; return `204` for `OPTIONS`; set `expires -1` and `Cache-Control: no-store, no-cache, must-revalidate`. | `_nginx/ampas-stage/rsvp/embed-routing.conf:21-50`; provisioner-owned auth path remains separate. |
| RSVP | production | Consider Amazon embed | R4 must add the same in-location CORS, preflight, and no-cache directives as staging. | `_nginx/ampas-prod/rsvp/embed-routing.conf:21-44`. |
| RSVP | local | Admin static extensions | The shared extension locations exclude `/admin/` with `^/(?!admin/)`; admin static responses therefore receive no generic static cache headers. | `_server/nginx/includes/static.conf:2,6,11,18,34,44,51,67,73`; retained for RS-04 local parity. R4 must ratify whether deployed admin caching wins. |
| RSVP | staging | Admin CSS/JS | The deployed generic CSS/JS location matches admin paths and emits `public, must-revalidate`, `expires 1h`, and `access_log off`. | `_nginx/ampas-stage/rsvp/static-files.conf:38-43`; R4 must ratify removal of the local admin guard or an intentional new-instance exception. |
| RSVP | production | Admin CSS/JS | The deployed generic CSS/JS location matches admin paths and emits `public, must-revalidate`, `expires 1h`, and `access_log off`. | `_nginx/ampas-prod/rsvp/static-files.conf:38-43`; R4 must ratify removal of the local admin guard or an intentional new-instance exception. |
| RSVP | local | Generic CSS/JS | The shared generic CSS/JS rule uses the RSVP legacy values `expires -1` and `no-store, no-cache, must-revalidate`, plus W3TC validators and fallback. | `_server/nginx/includes/static.conf:25-42` and `_server/nginx/server_blocks/rsvp.conf:18-20`; both the legacy and generic rules currently read the same `$site_css_*` variables. R4 must split the legacy rule onto deployed no-cache values before ratifying deployed values for the generic rule. |
| RSVP | staging | Generic CSS/JS | The deployed generic CSS/JS rule uses `public, must-revalidate`, `expires 1h`, and `access_log off`; only the legacy `/rsvp/` rule is no-cache. | `_nginx/ampas-stage/rsvp/static-files.conf:29-43`; this is moot for the retired hosted-page family under serving-surface ruling 7, but remains an explicit delta. |
| RSVP | production | Generic CSS/JS | The deployed generic CSS/JS rule uses `public, must-revalidate`, `expires 1h`, and `access_log off`; only the legacy `/rsvp/` rule is no-cache. | `_nginx/ampas-prod/rsvp/static-files.conf:29-43`; this is moot for the retired hosted-page family under serving-surface ruling 7, but remains an explicit delta. |
| RSVP | local | W3TC extension rules | The shared static include applies `etag`, `if_modified_since`, and `try_files` W3TC rules to non-admin RSVP paths. | `_server/nginx/includes/static.conf:65-78`; `_nginx/ampas-stage/rsvp/static-files.conf:1-68` and `_nginx/ampas-prod/rsvp/static-files.conf:1-68` have no RSVP W3TC section. R4 must ratify removing or scoping this extension. |
| RSVP | staging / production | W3TC extension rules | The shared tree would carry the W3TC extension unless R4 removes or scopes it. | The deployed RSVP sources above omit it; the W3TC rules are present in the WordPress sources, for example `_nginx/ampas-stage/wordpress/static-files.conf:59-77`, so this is not a WordPress omission. |

## Environment-specific security rules

| Site | Environment | Rule | Source and disposition |
|---|---|---|---|
| RSVP | staging | Content-Security-Policy host allowlist | Provisioner-owned: `infra/csp/staging.conf`, installed as `/etc/nginx/snippets/rsvp-staging-csp.conf` on every converge. The local harness intentionally emits no CSP. |
| RSVP | production | Content-Security-Policy host allowlist | Provisioner-owned: `infra/csp/production.conf`, installed as `/etc/nginx/snippets/rsvp-staging-csp.conf` on every converge. The local harness intentionally emits no CSP. |

The CSP values are environment-specific security policy, not byte-shared serving rules. Change
them in `infra/csp/` and converge, never on the instance ([`infra/README.md`](../infra/README.md),
"4. Keep the embed password manual"). No local request behavior depends on the omitted header.

## Coming-soon state

The AMPAS and Guilds production WordPress blocks are authored here so all three blocks can load
together under `nginx -t`. The deployed references show AMPAS and Guilds production behind
coming-soon placeholders. RS-06 owns their live serving proof and the driver-controlled return of
WordPress traffic; this packet does not deploy or cut traffic.

## Managed database connections

R4 run 4 consumes the existing Lightsail managed databases. Terraform and cloud-init do not create,
alter, or import databases. The driver supplies each connection through the root-only
`/root/amazon-staging/db.env` handoff described in `infra/README.md`; endpoints and credentials are
never checked into this repository.

| Site | Environment | Provisioner-owned values | Disposition |
|---|---|---|---|
| RSVP | staging | `RSVP_DB_HOST`, `RSVP_DB_PORT`, `RSVP_DB_NAME`, `RSVP_DB_USER`, `RSVP_DB_PASSWORD` | Driver supplies the existing managed-database connection; cloud-init only prepares the root-only handoff directory. |
| AMPAS | staging | `AMPAS_DB_HOST`, `AMPAS_DB_PORT`, `AMPAS_DB_NAME`, `AMPAS_DB_USER`, `AMPAS_DB_PASSWORD` | Driver supplies the existing managed-database connection; cloud-init only prepares the root-only handoff directory. |
| Guilds | staging | `GUILDS_DB_HOST`, `GUILDS_DB_PORT`, `GUILDS_DB_NAME`, `GUILDS_DB_USER`, `GUILDS_DB_PASSWORD` | Driver supplies the existing managed-database connection; cloud-init only prepares the root-only handoff directory. |
