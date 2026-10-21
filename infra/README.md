# Lightsail staging

This root module describes the co-located Ubuntu 24.04 Lightsail instances for RSVP,
AMPAS, and Guilds. Terraform owns the instance, static IPv4 address, attachment, and public ports.
Existing Lightsail CDN distributions, their domains and certificates, and the managed databases are
driver-owned and stay outside Terraform.

**Naming note:** "staging" in the surrounding names — the AWS profile and IAM policy/group
labels, the `amazon-staging-provision` script, the `STAGING_` variable prefix, the
`/root/amazon-staging` and template paths — is historical, from when this module only built
staging. Since the `environment` variable landed, the same names serve both environments;
normalizing them is tracked in the docs repo.

## Ground rules

1. **This repo must stay public.** The instance bootstrap clones it anonymously over
   HTTPS; a private repo means every fresh instance boots unprovisioned. The no-secrets
   rule is therefore existential, not hygiene.
2. **Run Terraform from the mini's clone**, in this directory, with the branch that
   carries `infra/` checked out (`develop` once RS-07 lands). The state file lives here
   and only here.
3. **Provision from landed branches.** The bootstrap clones the branch in the
   `server_branch` variable (default `develop`) and records it in
   `/etc/amazon-server.ref`; every converge follows that file. Staging follows
   `develop`; production follows `master`, and `amazon-server-converge` refuses any
   other ref there. Land serving-tree and `infra/` changes before converging a real
   instance. For a deliberate pre-land test build on staging, write the packet branch
   into `/etc/amazon-server.ref`, converge, and write `develop` back after land. On an
   instance created before the variable existed, a wrong-branch first boot fails at
   `infra/cloud-init.sh`; recover with the failed-first-boot procedure under
   "Instance access".
4. **Changing `user_data`, bundle, or blueprint replaces the instance.** Terraform
   destroys and recreates it on the next apply — deployed site code and hand-authored
   env files on the box are lost. Read the plan before applying to a live instance.
5. **Export the profile before any Terraform command:** `export AWS_PROFILE=<profile
   from IAM.md>` — the provider block does not name a profile, and without the export
   Terraform falls through to an IMDS lookup that fails confusingly off-EC2.
6. **The policy deliberately has no list/discovery actions** (no GetInstances,
   GetBundles, GetBlueprints, GetKeyPairs), so tfvars values come from the console or
   memory. Known-good values: region `us-west-2`, AZ `us-west-2a`,
   bundle `small_3_0` (2GB), blueprint `ubuntu_24_04`, key pair `AmazonStudiosAMPASkey`.

## Prerequisites

- Terraform `1.15.8` and the pinned HashiCorp AWS provider downloaded by `terraform init`.
- A named AWS profile created by [`IAM.md`](IAM.md), stored in `~/.aws/credentials`.
- An existing Lightsail key pair in the selected region. Terraform cannot create the key pair.
- The region's valid availability zone, Ubuntu 24.04 blueprint ID (`ubuntu_24_04`), and
  driver-selected bundle ID.
- Access to the existing CDN distributions and the provisioner-owned site releases and application
  database settings. This packet does not create databases or import dumps into them.

Terraform uses local state on the driver's mini. State and plan files are ignored by Git because
they can contain sensitive values.

Lightsail receives a single-line bootstrap, as required by the provider's `user_data` contract. It
installs Git, clones the serving repository at `develop`, and runs `infra/cloud-init.sh` from that
checkout. The full provisioner is not embedded in the instance launch payload. Later manual
re-runs use `/usr/local/sbin/amazon-staging-provision`.

## Driver sequence

Run these commands from this directory. The `plan` and `apply` steps are billable AWS operations
and are intentionally not run by the packet worker.

```bash
export AWS_PROFILE=amazon-lightsail-staging
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform fmt -check
terraform validate
terraform plan -out=staging.tfplan
terraform show staging.tfplan
terraform apply staging.tfplan

terraform output -raw static_ip
```

Set every value in `terraform.tfvars`. Keep the file on the driver's machine. `region` and
`bundle_id` have no defaults because they choose the billable location and instance size. The
`static_ip` output is the origin address used for direct checks and the later CDN origin flip.

## Production instance

The same module builds the production instance. The `environment` variable selects the value
set the provisioner renders (`staging` default): production server names, `HTTP_CI_ENV`,
production TLS paths, and no `.htpasswd` gate on the embed. The bootstrap records the choice
in `/etc/amazon-server.env` so provisioner re-runs keep rendering the same environment; an
absent marker means staging, which is what existing staging instances rely on. The CSP
snippet path (`snippets/rsvp-staging-csp.conf`) and the `db.env` handoff path are
environment-invariant — historical names, per-instance contents.

Build production beside the live staging instance, never over it:

```bash
export AWS_PROFILE=amazon-lightsail-staging
terraform workspace new production   # once; later: terraform workspace select production
cp terraform.tfvars production.tfvars
$EDITOR production.tfvars            # environment = "production", unique instance/static-ip names
terraform plan -var-file=production.tfvars -out=production.tfplan
terraform show production.tfplan     # gate: 4 to add, 0 to change, 0 to destroy
terraform apply production.tfplan
```

Keep production names out of `terraform.tfvars` so a later plan in the default workspace can
never propose replacing staging. `production.tfvars` also sets `server_branch = "master"` and
`auto_snapshot_time = "09:00"`: production takes daily automatic snapshots, and a plan without
that value would turn them off. Run plans from this directory: the workspaces and their state
live here, and `terraform workspace new` elsewhere starts an empty one. Every post-apply manual step below applies unchanged; the
production Guilds host binding has no deployed reference and needs an explicit driver
ratification before any CDN origin flip.

## Instance access

Temporary SSH comes from `lightsail:GetInstanceAccessDetails` (in `LightsailStagingRead`,
see [`IAM.md`](IAM.md)). Every call generates a fresh key-and-certificate pair, valid for
roughly five minutes. **Fetch both halves in one call** — a key from one call never
matches a certificate from another, and the mismatch presents as
`Permission denied (publickey)`.

```bash
aws lightsail get-instance-access-details --region us-west-2 \
  --instance-name amazon-fyc-staging --output json | python3 -c "
import json, sys, os
d = json.load(sys.stdin)['accessDetails']
open('ls-temp-key', 'w').write(d['privateKey'])
open('ls-temp-key-cert.pub', 'w').write(d['certKey'])
os.chmod('ls-temp-key', 0o600)"
ssh -i ls-temp-key ubuntu@<static-ip>
```

`ssh` pairs `ls-temp-key-cert.pub` with the key by filename. For durable operator
access, append an operator public key to `~ubuntu/.ssh/authorized_keys` over a temporary
session, then delete the temporary files. Never reuse repo deploy keys for shell access.

Both instances answer to the `amazon-lightsail-staging` AWS profile:

| Instance | Address | Access |
|---|---|---|
| `amazon-fyc-staging` | `ssh amazon-fyc-stage` (32.188.183.9) | durable operator key |
| `amazon-fyc-production` | `ubuntu@100.23.126.114` | no alias or stored key: fetch a temporary pair each session |

The tfstate address for production (184.32.228.99) is stale; do not probe it. Production
shell access is granted per release by the driver.

### Apply RSVP migrations on an instance

The instances have no `mysql` client. Apply a migration with PHP and the environment's
CodeIgniter config in the RSVP checkout (`admin/application/config/<environment>/database.php`):
define `BASEPATH`, include the config, open `mysqli` with `$db["default"]`, check
`SHOW COLUMNS ... LIKE` first, then run the `ALTER`. Print only column names and added or
present status, never config values. Migrations run before the checkout pull (RSVP
`docs/DEPLOYMENT.md`). Staging migrations are routine; production waits for the driver's go.

### Recover a failed first boot

When the bootstrap cloned a branch that lacks `infra/` (see ground rule 3),
`/var/log/cloud-init-output.log` ends with
`bash: /opt/amazon-server/infra/cloud-init.sh: No such file or directory`. Fix it over
temporary SSH. Record the branch that carries `infra/`, check it out, then run the
provisioner from the checkout:

```bash
ssh -i ls-temp-key ubuntu@<static-ip> \
  'echo <branch> | sudo tee /etc/amazon-server.ref &&
   sudo git -C /opt/amazon-server fetch --depth 1 origin <branch> &&
   sudo git -C /opt/amazon-server checkout --detach FETCH_HEAD &&
   sudo bash /opt/amazon-server/infra/cloud-init.sh'
```

Run this way, without the converge shim, the provisioner fetches the branch in
`/etc/amazon-server.ref` again and checks it out while it runs. If that moves the
checkout, bash can read a mix of old and new script bytes. So fetch the same branch
the ref file names. The run installs `amazon-server-converge`; use it for every later
run ("Converge and status").

## Converge and status

Every server-side config on an instance comes from this repo at the instance's ref.
One command applies it:

```bash
sudo amazon-server-converge
```

It reads `/etc/amazon-server.ref` (default `develop`) and `/etc/amazon-server.env`
(default `staging`). It refuses to run when the environment is `production` and the
ref is not `master`, or when `/opt/amazon-server` has uncommitted or untracked files.
It then fetches the ref, checks it out detached, and runs that checkout's
`infra/cloud-init.sh`. The provisioner skips its own fetch under the shim, so the
running script is never rewritten. `/usr/local/sbin/amazon-staging-provision` is a
symlink to the same command.

A run that gets through `nginx -t` and the reload writes two files:

- `/etc/amazon-server.applied`: `sha`, `ref`, `environment` and `applied_at` (UTC).
- `/var/lib/amazon-server/applied.sha256`: a hash of every provisioner-owned file. That
  is the nginx tree (except `.htpasswd` and the package files under `snippets/`), the
  CSP snippet, the PHP-FPM pools, the PHP settings and time zone files, the logrotate and
  apt-pin files, the templates, the reminder cron where installed, and the shim.

A failed run leaves the previous marker in place.

**PHP per site.** `infra/cloud-init.sh` sets `RSVP_PHP_VERSION`, `AMPAS_PHP_VERSION`,
`GUILDS_PHP_VERSION` and `PHP_CLI_VERSION`. `infra/php-sites.sh` derives the rest from them:

- Converge installs the package set for every version a site or the CLI uses, with one apt pin
  file each (`/etc/apt/preferences.d/amazon-php<version>`, digits only).
- Each site's pool is `/etc/php/<version>/fpm/pool.d/<site>.conf`, listening on
  `/run/php/php<version>-fpm-<site>.sock`, and nginx renders that socket.
- `update-alternatives --set php` keeps `/usr/bin/php` on `PHP_CLI_VERSION`, so installing a
  newer version never moves it.
- Every installed version gets `zz-amazon-timezone.ini` (`date.timezone = UTC`) in its
  `fpm/conf.d` and `cli/conf.d`.
- `/etc/amazon-server.php-sites` records what was applied, for status and the cache purge.

To move a site, change its value, land it, and converge. The new pool starts before nginx
reloads onto its socket. After the reload, converge deletes the site's pool from every other
version, restarts an FPM that lost a pool, and stops and disables an installed FPM left with no
pools. Its packages stay installed until close-out removes them. Rolling back is the same move
with the old value.

**First converge per instance.** Instances provisioned before the shim existed carry
an old full copy of the provisioner. Run the repo copy once; it installs the shim:

```bash
sudo git -C /opt/amazon-server fetch --depth 1 origin <ref>
sudo git -C /opt/amazon-server checkout --detach FETCH_HEAD
sudo bash /opt/amazon-server/infra/cloud-init.sh
```

Use the ref that `/etc/amazon-server.ref` names. Every later run is
`sudo amazon-server-converge`.

**Status.** `sudo amazon-server-converge status` changes nothing. It prints the
environment, the ref, the applied commit and time, the remote tip (`git ls-remote`),
the checkout commit and whether it is clean, the manifest check, the PHP checks, and the
manual checks. `status --short` prints one line for probes. The verdict:

| Verdict | Meaning | Exit |
|---|---|---|
| `CURRENT` | Applied commit is the remote tip for this environment, every owned file matches, manual checks pass | 0 |
| `BEHIND` | Applied commit is not the remote tip (or the remote could not be read) | 1 |
| `DRIFT` | An owned file changed or is missing, the manifest is missing or unusable, the marker names another environment or none, the checkout is dirty, or a manual check fails | 1 |
| `UNAPPLIED` | No `/etc/amazon-server.applied` marker | 1 |

`UNAPPLIED` wins over `DRIFT`, and `DRIFT` wins over `BEHIND`.

The same commit renders different staging and production configs, so a matching commit
alone is not `CURRENT`: the marker's `environment` must match `/etc/amazon-server.env`.
An empty, unreadable or malformed manifest, or a checksum run that fails without naming a
file, means no owned file was checked. Status prints each such cause on a `problem` line
(appended to the `--short` line) and reads `DRIFT`.

The manual checks print names, owners, modes, sizes, and pass or fail, never a value.
They cover `db.env` (missing warns, since nothing reads it after setup; a present file
must be root, mode 600, with the 15 key names), each WordPress `.env` (group
`www-data`, mode 640, the key names in step 2; a missing `DB_PORT` warns), each `auth.json`
(missing warns, since only Composer installs read it), the
staging `.htpasswd` (empty warns without changing the verdict, non-empty passes; not
checked on production), and the `~ubuntu/.ssh/config` alias each site checkout's
`origin` uses.

The PHP checks print each site's configured version, pool file and socket, each installed
version's FPM unit (active and enabled) and its pools, the installed `php*` packages and their
versions, and where `/usr/bin/php` points. Any of these is `DRIFT`: a missing pool, a pool
listening elsewhere, an absent socket, a site's pool left under another version, a used FPM
not running and enabled, an unused installed FPM not stopped and disabled, a configured
package not installed, or a CLI on another version.

**Hand edits show as drift.** A hand edit to an owned file reads as `DRIFT` until the
change lands in this repo, and the next converge overwrites it. Change the repo, land
it, then converge.

## Post-apply manual steps

Complete these steps on the new instance before changing a CDN origin. Re-run the provisioner at
any time with `sudo amazon-server-converge` ("Converge and status"); it re-renders the installed
nginx tree and ends with its own `nginx -t` gate.

### 1. Supply managed database connection values

The existing Lightsail managed databases already contain the site data. Do not install
`mariadb-server`, create databases or users, or import the old local dumps on this instance.

Create the root-only handoff file. Use the existing managed-database values supplied by the
provisioner. Do not put them in this repository or in command history.

```bash
sudo install -d -o root -g root -m 0700 /root/amazon-staging
sudoedit /root/amazon-staging/db.env
sudo chown root:root /root/amazon-staging/db.env
sudo chmod 600 /root/amazon-staging/db.env
```

The file contains these names, with the driver's real values:

```text
RSVP_DB_HOST=...
RSVP_DB_PORT=...
RSVP_DB_NAME=...
RSVP_DB_USER=...
RSVP_DB_PASSWORD=...
AMPAS_DB_HOST=...
AMPAS_DB_PORT=...
AMPAS_DB_NAME=...
AMPAS_DB_USER=...
AMPAS_DB_PASSWORD=...
GUILDS_DB_HOST=...
GUILDS_DB_PORT=...
GUILDS_DB_NAME=...
GUILDS_DB_USER=...
GUILDS_DB_PASSWORD=...
```

Use shell assignment syntax and quote values that contain shell metacharacters because the
connectivity check sources this file.

Check DNS and TCP reachability from the new instance. This does not authenticate, query, or print
any password.

```bash
sudo bash -s <<'CHECK'
set -Eeuo pipefail
db_env_file=/root/amazon-staging/db.env
source "$db_env_file"

for site in RSVP AMPAS GUILDS; do
  host_var="${site}_DB_HOST"
  port_var="${site}_DB_PORT"
  db_host="${!host_var:?${host_var} is missing}"
  db_port="${!port_var:?${port_var} is missing}"

  getent ahostsv4 "$db_host" >/dev/null
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$db_host" "$db_port"
  printf '%s: %s:%s reachable\n' "$site" "$db_host" "$db_port"
done
CHECK
```

Render each site's normal environment-specific application configuration from this handoff using
the existing provisioner mechanism. RSVP uses the `HTTP_CI_ENV=staging` staging path. AMPAS and
Guilds use their provisioner-owned WordPress environment files. This packet does not edit the site
repositories or commit those values.

### 2. Install the site releases

Deploy each site from its repository at its integration branch. Repository addresses and
branches are recorded in the private workspace doc (`_docs/WORKSPACE.md`) — do not name
them here. The docroots rendered by cloud-init are:

```text
RSVP application: /var/www/html/rsvp/admin/
RSVP public tree: /var/www/html/rsvp/public/
AMPAS WordPress:   /var/www/html/amazon-studios-ampas/web/
Guilds WordPress:  /var/www/html/amazon-studios-guilds/web/
```

**Deploy keys.** GitHub and GitLab accept a deploy key on exactly one repository, so
each site repo gets its own read-only ed25519 deploy key. Create each key on the
operator machine:

```bash
ssh-keygen -t ed25519 -N '' -C '<site> staging deploy (read-only)' -f ~/.ssh/<site>-deploy
```

Register the `.pub` half on the repo — GitHub: repo Settings → Deploy keys → Add deploy
key, write access off; GitLab: repo Settings → Repository → Deploy keys, read-only.
Copy the private halves to `~ubuntu/.ssh/` on the instance (mode 600) and give each
repo a `~/.ssh/config` alias so clones and pulls pick the right key:

```text
Host github-ampas
  HostName github.com
  User git
  IdentityFile ~/.ssh/<ampas-deploy-key>
  IdentitiesOnly yes
```

**Clones.** cloud-init pre-creates empty docroot skeletons so `nginx -t` passes before
any code exists. Remove each skeleton with `rmdir` — it refuses anything non-empty,
which is the safety you want — then clone into its place:

```bash
sudo rmdir /var/www/html/amazon-studios-ampas/web /var/www/html/amazon-studios-ampas
git clone --depth 1 --branch <integration-branch> \
  github-ampas:<org>/<repo>.git /var/www/html/amazon-studios-ampas
```

The rsvp skeleton nests an empty embed directory (`public/consideramazon/`), so plain
`rmdir` refuses it; delete its empty tree with the same non-empty safety:

```bash
sudo find /var/www/html/rsvp -depth -type d -empty -delete
```

**WordPress dependencies (AMPAS and Guilds).** cloud-init installs `unzip` and
Composer (phar installer — never `apt install composer`, which installs a second,
distribution PHP alongside the configured versions). Run `composer install --no-dev --no-interaction` at each WP
repo root. ACF Pro downloads from ACF's own composer repository and prompts for
credentials: **username is the license key, password is a site URL registered to that
license** (register URLs in the ACF account first). Let Composer store them in the
repo's `auth.json` — it is gitignored and must never be committed. Dependencies
install natively on every machine; never copy `vendor/` or plugin trees between
machines.

**Theme assets.** The built theme `dist/` trees are committed, and cloud-init installs
Node and npm so themes can also be rebuilt on the instance (`npm ci && npm run build`
in the theme directory). The on-instance path exists because GitHub Actions do not yet
compile and deploy the assets; remove Node from cloud-init once they do.

**Writable paths.** Clones stay owned by `ubuntu`; PHP-FPM runs as `www-data` and needs
write access only where the applications write. Create `web/app/uploads` per WP site
and `chown -R www-data:www-data` it; give RSVP's runtime log directory
(`admin/application/logs/`) to `www-data` the same way. Leave everything else
read-only to `www-data`.

**Site environment files.** Author each site's env file on the instance by hand from
the `db.env` handoff (step 1). A WP `.env` needs exactly these names (values never
leave the instance):

```text
DB_NAME  DB_USER  DB_PASSWORD  DB_HOST  DB_PORT
WP_ENV=<staging|production>  WP_HOME=https://<site-host>  WP_SITEURL=${WP_HOME}/wp
AUTH_KEY  SECURE_AUTH_KEY  LOGGED_IN_KEY  NONCE_KEY
AUTH_SALT  SECURE_AUTH_SALT  LOGGED_IN_SALT  NONCE_SALT
```

(The ACF license lives in Composer's gitignored `auth.json`, not in `.env`.)

Generate the eight salts fresh per site — never copy them between environments:

```bash
for s in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
         AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
  printf "%s='%s'\n" "$s" "$(openssl rand -base64 48 | tr -d '\n')"
done
```

RSVP needs no env file — its
environment-specific config is selected by the FastCGI `HTTP_CI_ENV=staging`
already rendered into the server block, and RSVP deploys by clone alone (no Composer
step). Set every `.env` to `chown <deploy-user>:www-data` and `chmod 640` — PHP-FPM
reads it as `www-data`, and a `600`-mode file owned by the deploy user turns the whole
site into a 500. Leave the `WPOSES_AWS_*` mail keys out until the mail-path issue (#74)
closes — without them staging cannot send mail, which is the intended state.

Preserve the repository layouts used by the local nginx stack. Do not put `.env` files,
certificates, htpasswd hashes, or credentials in this repository.

### 3. Configure optional origin TLS

By default, the existing CDN distributions terminate TLS and the new instance serves HTTP as their
origin. Do not change DNS and do not run certbot for that setup. The domains and certificates stay
attached to the distributions.

If the driver deliberately chooses an HTTPS-only origin policy, obtain origin certificates with the
driver's approved certbot/ACME method. Public DNS must remain pointed at the distributions. Put the
resulting files at the provisioner-owned paths already used by cloud-init, then re-run:

```bash
sudo /usr/local/sbin/amazon-staging-provision
```

The re-run renders HTTP-to-HTTPS redirects and TLS listeners only after all three certificate pairs
exist. `nginx -t` must pass before the distribution origin policy changes.

### 4. Keep the embed password manual

The RSVP CSP is provisioner-owned: `infra/csp/<environment>.conf` is installed as
`/etc/nginx/snippets/rsvp-staging-csp.conf` on every converge. Change the policy in this
repo, never on the instance.

Only the staging embed password stays manual. Its contents never enter Terraform or Git.
**Production has no embed htpasswd gate** (the provisioner leaves the `$rsvp_auth` map
default at `off`); skip this step there. While the staging file is empty, a direct visit
to the staging embed gets 401 and only the origins the `$rsvp_auth` map exempts get
through.

```bash
sudo htpasswd -c /etc/nginx/.htpasswd <staging-user>
sudo chown root:www-data /etc/nginx/.htpasswd
sudo chmod 640 /etc/nginx/.htpasswd
```

nginx workers read the file on each login as `www-data`, so no reload is needed. A root-only
file turns every login into a 500. Converge keeps the file at `root:www-data` `640`.

### 5. Install the scheduled jobs

The provisioner owns the only scheduled job. Nothing fails when a job is missing; the work it
does just stops.

**RSVP reminders (production only).** The job runs hourly and mails each attendee 20 to 24 hours
before their screening. A missed hour is harmless; a missing job silently skips every reminder.
Staging has no reminder job; add one only on the driver's call.

Converge installs `infra/cron/amazon-rsvp-reminders` as `/etc/cron.d/amazon-rsvp-reminders`
(root, 0644) only when all three hold: the environment is production,
`/var/www/html/rsvp/admin/application/scripts/run_reminder.production.sh` is executable, and
that wrapper contains no `/opt/bitnami` path. Otherwise it prints a warning and leaves any
existing file byte-for-byte as it is. So on a new production
instance the job starts with the first converge after the RSVP release is in place. If an old
instance still runs the job, remove its cron file first: two hourly runs can race and mail the
same attendees twice.

Dry-run first, as the job's user. A dry run sends nothing and writes nothing:

```bash
rsvp_php="$(awk -F= '$1 == "rsvp_php" { print $2 }' /etc/amazon-server.php-sites)"
sudo -u www-data HTTP_CI_ENV=production "$rsvp_php" \
  /var/www/html/rsvp/admin/index.php reminders send_reminders dry_run
```

Then converge (`sudo amazon-server-converge`) and check that the run printed no reminder-cron
warning.

The script sets `HTTP_CI_ENV=production`, which is required. The CLI has no FastCGI param, and
without it the mail guard sends to the non-production recipients instead of attendees (RSVP
`docs/DEPLOYMENT.md`, "Outgoing mail"). The cron line sets `PHP_BIN` to RSVP's configured
binary (`RSVP_PHP_VERSION` in `infra/cloud-init.sh`), so the job moves with the site's pool.

After the next full hour, confirm the job ran: the newest
`/var/www/html/rsvp/admin/application/logs/reminders-*.log` holds an `Environment: production`
block for that hour.

### 6. Flip the existing CDN origins

Cutover is an origin change on the existing distributions, not a DNS change:

1. Record each distribution's current origin for rollback.
2. Set each distribution's origin to the new instance's `static_ip` output using the driver's
   existing Lightsail distribution workflow.
3. Keep the distribution domains and certificates unchanged, and wait for the distribution to
   finish propagating.
4. Run the public serving matrix below through the distribution hostnames.

Rollback is the same operation in reverse: restore each recorded old origin. Terraform does not
manage or modify any distribution.

### New distributions, certificates, and DNS (production cutover, 2026-09-01)

When cutting over with fresh distributions instead of an origin flip, the certificate dance has
sharp edges — all learned the hard way:

1. **A domain attaches to one distribution at a time**, and the claim lives with the
   distribution's **attached certificate**, not its custom-domain toggles. "Already associated
   with a different resource" means an old distribution still holds an attached cert carrying
   that SAN — detach the cert there (or delete the distribution) to release it. An attached
   cert also cannot be deleted.
2. **Distribution certificates are Lightsail-created, us-east-1 only.** CLI checks and
   attaches need `--region us-east-1` explicitly; without it the cert "does not exist".
   The console's "Attach certificate" picker lags several minutes behind reality — the CLI
   attach by exact `certificateName` is authoritative:
   `aws lightsail attach-certificate-to-distribution --region us-east-1 --distribution-name <d> --certificate-name <c>`.
3. **Match the SAN list to the provisioner's server names** before attaching — a cert carrying
   legacy-domain SANs routes those hosts to whatever server block is default. The five
   production names are the ENV-DELTAS rows.
4. **Recreate under a new name** if a cert was just deleted — a reused name can hit ghost
   state.
5. **The distribution caches what it sees at attach time.** After flipping site state (for
   example the coming-soon toggle), reset the distribution cache or visitors keep the old
   pages.

DNS records point at the distribution domains and stay outside Terraform; record the previous
values before switching, and rollback is restoring them.

## Host state outside Git

Converge rebuilds the nginx tree, packages, PHP-FPM pools, logrotate rule, docroot skeletons,
the RSVP CSP snippet (`infra/csp/`), and on production the RSVP reminder cron (`infra/cron/`).
Those are provisioner-owned and listed in the applied manifest ("Converge and status").
Everything below lives only on the instance. A replaced instance loses it, and nothing fails
loudly when it is missing. Each row names the step that recreates it and what
`amazon-server-converge status` checks.

| State | Where on the instance | Environments | Recreated by | `status` checks |
|---|---|---|---|---|
| Environment marker | `/etc/amazon-server.env` | production (absent means staging) | Bootstrap ("Production instance") | Prints it |
| Converge ref | `/etc/amazon-server.ref` | both | Bootstrap; edited for a pre-land test build (ground rule 3) | Prints it |
| Managed-database handoff | `/root/amazon-staging/db.env` | both | Step 1 | Owner, mode, key names |
| Deploy keys and SSH aliases | `~ubuntu/.ssh/` | both | Step 2 | Each site's alias; not the keys |
| Site releases | `/var/www/html/{rsvp,amazon-studios-ampas,amazon-studios-guilds}` | both | Step 2 | No |
| WordPress `.env` files | each WP repo root | both | Step 2 | Group, mode, key names |
| ACF Composer credentials | each WP repo's `auth.json` | both | Step 2 | Present, else warns |
| Writable-path ownership | WP `web/app/uploads`, RSVP `admin/application/logs/` | both | Step 2 | No |
| Uploaded media | WP `web/app/uploads` | both | No step yet: copy from the instance being replaced | No |
| Origin TLS certificates | provisioner-owned certificate paths | when HTTPS-only origin is chosen | Step 3 | No |
| Embed password | `/etc/nginx/.htpasswd` | staging | Step 4 | Empty warns, non-empty passes |

Two rules keep this table complete:

1. **Add a row in the same change** that puts anything new on an instance by hand: a cron entry,
   a systemd timer, a config override, a credential file.
2. **Audit the old instance before retiring it.** List its scheduled jobs and hand-edited config,
   and match each item to a row. Copy anything unlisted, then add its row.

```bash
sudo cat /etc/crontab
sudo ls /etc/cron.d /var/spool/cron/crontabs
for u in root ubuntu www-data bitnami daemon; do echo "== $u"; sudo crontab -l -u "$u" 2>/dev/null; done
systemctl list-timers --all
```

## Staging verification

Run the ratified must-serve matrix in
[`restructure-serving-surface.md`](../../_docs/rsvp/reference/restructure-serving-surface.md) against the static IP before
and after the origin flip. Compare against the **current landed local matrix capture** (the latest
`_artifacts/RS-*` final matrix), never a historical one — the hosted/direct page family 404s by
driver ruling 7 (2026-08-12), and API validation rules move with the code, so older baselines
report false failures. Use `--resolve` for direct-origin checks so the Host header remains the
staging name. The default origin policy uses port 80:

```bash
staging_ip="$(terraform output -raw static_ip)"
for host in \
  stg.rsvp.amazonmgmstudiosawards.com \
  stg.amazonmgmstudiosawards.com \
  stg.amazonmgmstudiosguilds.com; do
  curl --resolve "$host:80:$staging_ip" \
    --fail --silent --show-error \
    "http://$host/"
done

curl --resolve "stg.rsvp.amazonmgmstudiosawards.com:80:$staging_ip" \
  -i --silent --show-error -X OPTIONS \
  -H 'Origin: https://consideramazon.com' \
  -H 'Access-Control-Request-Method: GET' \
  'http://stg.rsvp.amazonmgmstudiosawards.com/rsvp/consideramazon/'
```

If the driver selected HTTPS-only origin TLS, use port 443 and `https://` for the direct-origin
checks after the certificate-ready re-render. After the CDN origin flip, repeat the same matrix
through the normal distribution hostnames. Check status and response headers, not only bodies.

The live matrix, PHP-FPM startup, managed-database application login, certificate behavior, CDN
propagation, and browser smoke are driver checks after apply. Do not submit RSVPs or exercise any
email-sending path during this packet.

## Teardown

After an explicit driver decision, audit the instance against "Host state outside Git" and
restore the recorded CDN origins first, then run:

```bash
terraform destroy
```

Never delete the instance or static IP in the Lightsail console: Terraform's state goes
stale, and a static IP left allocated but unattached keeps billing. Always destroy from
this directory.

Destroy removes the Terraform-managed Lightsail instance, public-port rules, static-IP attachment,
and static IP. It does not remove CDN distributions, their domains or certificates, DNS records,
managed databases, the driver's Lightsail key pair, or the local Terraform state file.
