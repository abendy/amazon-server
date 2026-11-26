# Lightsail staging

This root module describes the co-located Ubuntu 24.04 Lightsail instances for RSVP,
AMPAS, and Guilds. Terraform owns the instance, static IPv4 address, attachment, and public ports.
The CloudFront distributions in front of the sites (with their certificates, web ACLs and logs),
the site and `origin.` DNS records, and the managed databases are driver-owned and stay outside
Terraform. The distributions' setup and history are in `_docs`
`platform/plans/archive/20261123-cloudfront-pro-move/`.

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
- Access to the CloudFront distributions, the `origin.` DNS records, and the provisioner-owned site releases and application
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
`static_ip` output is the origin address used for direct checks and the later origin switch.

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
never propose replacing staging. `production.tfvars` also sets `server_branch = "master"`, and both
workspaces set `auto_snapshot_time = "11:00"` (6 AM Eastern in winter, 7 AM in summer): each
instance takes daily automatic snapshots, and a plan without that value would turn them off. Run plans from this directory: the workspaces and their state
live here, and `terraform workspace new` elsewhere starts an empty one. Every post-apply manual step below applies unchanged; the
production Guilds host binding has no deployed reference and needs an explicit driver
ratification before any origin switch.

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
define `BASEPATH` and `APPPATH` (`/var/www/html/rsvp/admin/application/`), include the config,
open `mysqli` with `$db["default"]`. Check the target first (`SHOW COLUMNS ... LIKE` for an
`ALTER`, `SHOW TABLES LIKE` for a `CREATE TABLE`), then run the statement. Print only column or
table names and added or present status, never config values. The config reads its login from
`secrets.json` (`docs/ENV-DELTAS.md`, "RSVP secrets file") once that loader is deployed, and needs
`APPPATH` to find it. Migrations run before the checkout pull (RSVP
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
  apt-pin files, the templates, the reminder cron where installed, the staging MySQL config
  files, and the shim.

A failed run leaves the previous marker in place.

**Staging database server.** On staging only, `infra/mysql-local.sh` installs MySQL 8.0 from
Ubuntu's packages, so the staging sites can move off their managed databases. Production
converge skips it and keeps its managed databases.

- A 1 GiB `/swapfile`, active and in `/etc/fstab`, guards against the out-of-memory killer
  when MySQL and PHP-FPM peak together.
- `/etc/mysql/mysql.conf.d/zz-amazon-parity.cnf` is `mysql/server-parity.cnf` as is: the
  managed servers' `sql_mode`, character set, collation, time zone and limits.
- `/etc/mysql/mysql.conf.d/zz-amazon-staging.cnf` is `infra/mysql/staging-local.cnf`: listeners
  on `127.0.0.1` only and a 256 MB buffer pool. It stays out of `mysql/` because the local Docker
  stacks mount that folder as their MySQL config: only settings shared with them belong there.
- The config goes in before the packages, so a first install starts on it. A later config
  change restarts MySQL; an unchanged one leaves it running.
- The named time zone tables load from the host's tzdata, and reload when the `tzdata` package
  changes (`/var/lib/amazon-server/mysql-tzdata.version`). RSVP's screening clock converts to
  each city's zone with `CONVERT_TZ`, which returns NULL for a zone the server has not loaded.

Status adds a `local db` group on staging. It checks that MySQL runs, that nothing listens on
3306 or 33060 beyond `127.0.0.1`, that every `[mysqld]` value in both installed files matches
the running server, that a named zone converts, and that the swap file is active. Root reads the values over the socket.

**Encode review tool.** On staging only, `infra/encode-review.sh` installs **Media → Optimize
video**, the trailer encode and review tool ([`encode-review/README.md`](../encode-review/README.md)).
Production converge installs and renders nothing for it.

- `ffmpeg` from Ubuntu, and Netflix's `vmaf` tool at `/opt/encode-review/bin/vmaf`: the pinned
  upstream release, SHA-256 checked, because Ubuntu's `ffmpeg` has no `libvmaf`. It downloads
  only when the installed copy is missing or from another archive.
- The `encode-review` system user. `www-data` joins its group, so PHP-FPM can write uploads into
  the spool; converge reloads the AMPAS and Guilds PHP-FPM units the one time it adds the group.
- The spool `/srv/encode-review/` and its folders, `encode-review:encode-review`, mode 2775.
- `/etc/systemd/system/encode-review-worker.service` with its limits (`MemoryMax=800M`,
  `MemorySwapMax=0`, `CPUQuota=150%`, `Nice=19`, `IOSchedulingClass=idle`). Converge restarts
  it exactly when what it loads at start changes: the unit or a drop-in, the worker code in the
  checkout, or the login file's contents. It records the digest the worker started with in
  `/var/lib/encode-review/worker-state` (root-only); an unchanged converge leaves a running
  encode alone.
- `/etc/needrestart/conf.d/encode-review.conf`, so needrestart (run by unattended upgrades)
  never restarts the worker after a library update and cuts off a running encode. The worker
  picks up new libraries at its next restart (converge, or a reboot).
- When `/root/amazon-staging/encode-review-production.env` exists, a drop-in passes it to the
  worker with `LoadCredential=` (the production upload login, a driver step).
- No upload pool: uploads arrive in 64 MiB parts through each site's own pool and limits.
  Converge removes the `<site>-encode-review-upload` pools an earlier build installed and reloads
  that PHP-FPM; status counts any left as pools left behind.
- The must-use plugin in each WordPress site's `web/app/mu-plugins/encode-review/`, which both
  site repositories ignore. It belongs to `ubuntu`, like the rest of the checkout.
- `/etc/nginx/snippets/encode-review.conf` (an `internal` location onto the spool, for playback)
  and its include in the staging AMPAS and Guilds server blocks (`docs/ENV-DELTAS.md`).

Status adds an `encode review` group on staging: the service, whether it runs what converge last
started it with, the unit's limits, the spool's owner and mode with `www-data` in the group,
`ffmpeg` and `vmaf`, the plugin matching the checkout in both sites, free disk (under 10 GiB warns: uploads are refused), and the production
login (absent warns: Send to production is off).

**PHP per site.** `infra/cloud-init.sh` sets `RSVP_PHP_VERSION`, `AMPAS_PHP_VERSION`,
`GUILDS_PHP_VERSION` and `PHP_CLI_VERSION`. `infra/php-sites.sh` derives the rest from them:

- Converge installs the package set for every version a site or the CLI uses, with one apt pin
  file each (`/etc/apt/preferences.d/amazon-php<version>`, digits only).
- Each site's pool is `/etc/php/<version>/fpm/pool.d/<site>.conf`, listening on
  `/run/php/php<version>-fpm-<site>.sock`, and nginx renders that socket.
- `update-alternatives --set` keeps `/usr/bin/php`, `/usr/bin/phar` and `/usr/bin/phar.phar` on
  `PHP_CLI_VERSION`, so installing a newer version never moves them.
- Every configured version gets `zz-amazon-timezone.ini` (`date.timezone = UTC`) in its
  `fpm/conf.d` and `cli/conf.d`.
- Every configured version gets `zz-amazon-security.ini` (`session.upload_progress.enabled = 0`,
  CVE-2026-109619) in its `fpm/conf.d`. No site uses upload progress.
- `/etc/amazon-server.php-sites` records what was applied, for status and the cache purge.

To move a site, change its value, land it, and converge. The new pool starts before nginx
reloads onto its socket. After the reload, converge deletes the site's pool from every other
version, reloads an FPM that lost a pool, and stops and disables an installed FPM left with no
pools. Then it purges every version that no site and not the CLI uses, with its pin and its
`/etc/php/<version>` folder. Status reports any such version still installed as a problem.
Rolling back is the same move with the old value; converge installs the old version again.

**When converge touches PHP-FPM.** A restart cuts off uploads and long requests in flight, so
converge fingerprints each version's packages, ini files and pool files before its PHP steps and
compares them afterwards. It restarts an FPM whose packages or ini changed, or that is not
running; reloads (`systemctl reload`) one whose pool files alone changed; and leaves the rest
alone, so a converge that changes nothing about PHP does not touch it. A reload is only as gentle
as `process_control_timeout`, which stays at PHP's default (`0`): in-flight requests still end.

**PHP package source.** PHP comes from packages.sury.org, where Ondrej Sury is moving the
`ppa:ondrej/php` packages. Converge installs the `debsuryorg-archive-keyring` package for the
archive key, writes `/etc/apt/sources.list.d/php-sury.sources`, and removes the old PPA source. A
PPA build sorts above the same version on packages.sury.org, and new PHP packages refuse to install
beside it. So the first converge after the switch reinstalls every Sury-built package at the
version packages.sury.org serves (`apt-get install --allow-downgrades`), which restarts PHP-FPM
once. Later converges find nothing to move.

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
the checkout commit and whether it is clean, the manifest check, the PHP checks, the OS patch
checks (see "OS patches"), the time zone checks, and the manual checks. `status --short` prints one line for probes.
The verdict:

| Verdict | Meaning | Exit |
|---|---|---|
| `CURRENT` | Applied commit is the remote tip for this environment, every owned file matches, manual checks pass | 0 |
| `BEHIND` | Applied commit is not the remote tip (or the remote could not be read) | 1 |
| `DRIFT` | An owned file changed or is missing, the manifest is missing or unusable, the marker names another environment or none, the checkout is dirty, automatic security updates are off, a time zone is not UTC, or a manual check fails | 1 |
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
checked on production), the production reminder ping URL file (missing, empty, or not
`root:www-data` mode 640 warns; not checked on staging), and the `~ubuntu/.ssh/config` alias
each site checkout's `origin` uses.

The PHP checks print each site's configured version, pool file and socket, each installed
version's FPM unit (active and enabled) and its pools, the installed `php*` packages and their
versions, and where `/usr/bin/php` points. Any of these is `DRIFT`: a missing pool, a pool
listening elsewhere, an absent socket, a site's pool left under another version, a used FPM
not running and enabled, an unused installed FPM not stopped and disabled, a configured
package not installed, or a CLI on another version.

**Time zones.** Everything runs in UTC; Pacific time belongs in code that names it, never in a
server default. Converge writes `date.timezone = UTC` for PHP (above) and sets the host to
`Etc/UTC` when it differs. `status` prints the host zone, the CLI's PHP zone, each FPM version's
`date.timezone`, and each site database's global and session zones, read with that site's own
login (WordPress `.env`; RSVP's `secrets.json`, or an older `database.php`). Any zone other than
UTC is `DRIFT`. A database it cannot read only warns. The managed databases are outside
Terraform, so a non-UTC database zone is a Lightsail parameter change for the driver.

**Hand edits show as drift.** A hand edit to an owned file reads as `DRIFT` until the
change lands in this repo, and the next converge overwrites it. Change the repo, land
it, then converge.

## OS patches

Both instances run Ubuntu's `unattended-upgrades` with its stock configuration. Every day it
refreshes the package lists and installs updates from the security pocket (`noble-security`,
plus the ESM security origins). Nothing else installs by itself:

- updates from `noble-updates`, including fixed kernels that Ubuntu publishes there first;
- PHP packages from packages.sury.org (see "PHP package source");
- reboots, which kernel and libc updates need before they take effect.

Those wait for the **patch window**: once a month, and sooner when a critical CVE needs a
package outside the security pocket. The driver owns the window and gives the go for each
instance.

**Status.** The patch section of `status` reads the cached lists and changes nothing:

| Line | Reports | Effect |
|---|---|---|
| `auto updates` | Both apt timers active and enabled, `APT::Periodic::Unattended-Upgrade "1"`, a security origin allowed | `FAIL` is `DRIFT` |
| `package lists` | Hours since the last successful daily refresh | warns over 48 hours |
| `security` | Security updates still waiting | warns when any wait: the daily job should have taken them |
| `updates` | Other updates waiting for the window | info |
| `php` | PHP packages waiting for the window, by name | info |
| `reboot` | `/var/run/reboot-required` and the packages that set it | warns |
| `kernels` | Running kernel and installed images | warns over three images |

**The window.** Patch staging, check it, then patch production the same way. Per instance:

1. Run `sudo amazon-server-converge status` and note the patch lines.
2. Take a snapshot from the operator machine and wait for `available`. Only the backup profile
   can create and read snapshots (`IAM.md`):

   ```bash
   AWS_PROFILE=amazon-lightsail-backup aws lightsail create-instance-snapshot \
     --region us-west-2 --instance-name amazon-fyc-staging \
     --instance-snapshot-name "amazon-fyc-staging-pre-patch-$(date +%Y%m%d)"
   ```

3. Preview, then apply. Pick a time away from the top of the hour, when the RSVP reminder
   cron runs:

   ```bash
   sudo apt-get update
   sudo apt-get -s dist-upgrade | grep '^Inst'
   sudo DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade
   ```

   A PHP update restarts PHP-FPM. Read the preview before applying, because a
   package that wants to remove another one needs a closer look.
4. Reboot if `status` reports one: `sudo systemctl reboot`.
5. Remove old kernels: `sudo apt-get -y autoremove --purge`. Ubuntu keeps the running kernel
   and the two newest ones.
6. Check the instance:
   - `status` reads `CURRENT`, with `reboot` not required;
   - `uname -r` is the newest installed kernel;
   - `nginx`, PHP-FPM, `ssh` and `cron` are running;
   - each site answers through CloudFront and at the origin as it did before.
   Record the snapshot name, the package count and the results on the covering issue.

To roll back, create an instance from the snapshot (`aws lightsail
create-instances-from-snapshot`) and move the static IP to it.

## Post-apply manual steps

Complete these steps on the new instance before switching the origin to it. Re-run the provisioner at
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
read-only to `www-data`. Converge keeps the folders it creates for the checkouts (the RSVP
root, `public/`, `public/consideramazon/`, each WP `web/`) owned by `ubuntu`, so git, Composer
and the embed apply all run as `ubuntu`. `status` fails on a checkout folder not owned by
`ubuntu`, a writable path not owned by `www-data`, or any root-owned file in a checkout (left by
a deploy run as root).

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

By default, the CloudFront distributions terminate TLS and the new instance serves HTTP as their
origin. Do not change the site DNS and do not run certbot for that setup. The domains and
certificates stay on the distributions.

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

The provisioner owns both scheduled jobs, the RSVP reminders and the RSVP confirmation retries.
Nothing on the server fails when a job is missing; the work it does just stops. An outside check
watches the reminder job ("Dead-man switch" below).

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
block for that hour. A run the wrapper refused or could not log leaves its error lines in
syslog: `journalctl -t amazon-rsvp-reminders`.

**RSVP confirmation retries (production only).** RSVP sends each confirmation inside the RSVP
request. This job sends the ones that did not go out: refused temporarily by the mail server before
it took the message (a 4xx reply, or none), or never sent because the request's send never ran. A
permanent refusal (5xx) is not retried. It picks RSVPs 10 minutes to 48 hours old, for visible
screenings that have not started, and rechecks each one just before sending (RSVP
`docs/DEPLOYMENT.md`, "Outgoing mail"). It runs
every 15 minutes, at :05, :20, :35 and :50, so it never starts with the hourly reminder job. A
missed run is harmless; a missing job leaves those confirmations unsent.

Converge installs `infra/cron/amazon-rsvp-confirmations` as
`/etc/cron.d/amazon-rsvp-confirmations` (root, 0644) under the same three conditions as the
reminder cron, for `/var/www/html/rsvp/admin/application/scripts/run_confirmations.production.sh`.
Otherwise it prints a confirmation-cron warning and leaves any existing file as it is.

Dry-run first, as the job's user. A dry run sends nothing and writes nothing:

```bash
rsvp_php="$(awk -F= '$1 == "rsvp_php" { print $2 }' /etc/amazon-server.php-sites)"
sudo -u www-data HTTP_CI_ENV=production "$rsvp_php" \
  /var/www/html/rsvp/admin/index.php confirmations send_due dry_run
```

After the next quarter hour, confirm the job ran: the newest
`/var/www/html/rsvp/admin/application/logs/confirmations-*.log` holds an `Environment: production`
block and a `Confirmations:` summary. Every run keeps a log, so about 96 a day, for 30 days. A run
the wrapper refused or could not log leaves its error lines in syslog:
`journalctl -t amazon-rsvp-confirmations`. This job pings no outside monitor.

**Dead-man switch (production only).** A healthchecks.io check emails the driver when the
reminder job stops pinging it or reports a failure. The cron line reads the check's ping URL at
each run from `/etc/amazon-server.reminder-ping-url`, which lives only on the instance; without
it the job runs as before and pings nothing. Setup, proof, and the alert test are in
[`docs/HEALTHCHECKS.md`](../docs/HEALTHCHECKS.md).

### 6. Switch the origin to the new instance

The CloudFront distributions reach the origin by hostname: production through
`origin.amazonmgmstudiosawards.com`, staging through `origin.stg.amazonmgmstudiosawards.com`. Each
is an A record (TTL 300) to the instance's static IP. Cutover is that one DNS change; the
distributions and the site names stay as they are.

1. Run the direct-origin matrix ("Staging verification") against the new `static_ip`, before the
   instance has an origin lockdown secrets file.
2. Copy `/etc/amazon-server.origin-auth` from the old instance (root, 600) and converge
   ("Origin lockdown"). A direct request now gets 403.
3. Record the `origin.` record's current value, then point it at the new `static_ip`.
4. After the old TTL (5 minutes), run the matrix through the site names.

Rollback is restoring the recorded A record value. Terraform does not manage the record or any
distribution.

Moving the site names themselves between distributions (as in the 2026-11-25 move from the
Lightsail CDN to CloudFront) is a different job: its scripts, order and lessons are in `_docs`
`platform/plans/archive/20261123-cloudfront-pro-move/`. The site names are Route 53 alias records to the
distributions and stay outside Terraform.

## Host state outside Git

Converge rebuilds the nginx tree, packages, PHP-FPM pools, logrotate rule, docroot skeletons,
the RSVP CSP snippet (`infra/csp/`), and on production the RSVP reminder and confirmation crons
(`infra/cron/`).
Those are provisioner-owned and listed in the applied manifest ("Converge and status").
Everything below lives only on the instance. A replaced instance loses it, and nothing fails
loudly when it is missing. Each row names the step that recreates it and what
`amazon-server-converge status` checks.

| State | Where on the instance | Environments | Recreated by | `status` checks |
|---|---|---|---|---|
| Environment marker | `/etc/amazon-server.env` | production (absent means staging) | Bootstrap ("Production instance") | Prints it |
| Converge ref | `/etc/amazon-server.ref` | both | Bootstrap; edited for a pre-land test build (ground rule 3) | Prints it |
| Managed-database handoff | `/root/amazon-staging/db.env` | production (staging has no managed databases since 2026-11-20) | Step 1 | Owner, mode, key names; absent only warns |
| Local database data and logins | MySQL schemas `ampas`, `guilds`, `rsvp` and their users; passwords in `/root/amazon-staging/local-db.env` (root, 600) | staging | `_docs` `platform/plans/archive/20261120-staging-db-on-instance/` (copy script), or `scripts/sync-data.py` from production | The server only (`local db` group), not the data |
| Encode review spool | `/srv/encode-review/`: originals, attempts, and one send record per attachment sent to production | staging | Not recreated: jobs expire 7 days after their last activity, approved files are in Media. A finished send is also on the staging attachment (`_encode_review_send`), which still blocks a second send | Folders, owner and mode (`encode review` group), not the jobs |
| Encode review production login | `/root/amazon-staging/encode-review-production.env` (root, 600) | staging | [`encode-review/README.md`](../encode-review/README.md), "Send to production: driver steps" | Present, else warns |
| Production upload-only role and user | `upload_only` role, its user and application password, in each production WordPress database | production | [`encode-review/README.md`](../encode-review/README.md), "Send to production: driver steps" | No |
| Database move dumps and login backups | `/root/amazon-staging/db-move/` | staging | Not recreated: a record of the 2026-11-20 move | No |
| Deploy keys and SSH aliases | `~ubuntu/.ssh/` | both | Step 2 | Each site's alias; not the keys |
| Site releases | `/var/www/html/{rsvp,amazon-studios-ampas,amazon-studios-guilds}` | both | Step 2 | No |
| WordPress `.env` files | each WP repo root | both | Step 2 | Group, mode, key names |
| ACF Composer credentials | each WP repo's `auth.json` | both | Step 2 | Present, else warns |
| RSVP secrets file | `/var/www/html/rsvp/admin/application/config/<environment>/secrets.json` | both | `docs/ENV-DELTAS.md`, "RSVP secrets file" | No |
| Writable-path ownership | WP `web/app/uploads`, RSVP `admin/application/logs/` | both | Step 2 | No |
| Uploaded media | WP `web/app/uploads` | both | No step yet: copy from the instance being replaced | No |
| Origin TLS certificates | provisioner-owned certificate paths | when HTTPS-only origin is chosen | Step 3 | No |
| Embed password | `/etc/nginx/.htpasswd` | staging | Step 4 | Empty warns, non-empty passes |
| Reminder ping URL | `/etc/amazon-server.reminder-ping-url` | production | [`docs/HEALTHCHECKS.md`](../docs/HEALTHCHECKS.md) | Owner, mode, empty; else warns |
| Origin lockdown secrets | `/etc/amazon-server.origin-auth` (root, 600) | both | "Origin lockdown": the secret is also in each CloudFront distribution's origin settings | Owner, mode, count, enforced; missing warns |
| IPv4 TCP mitigation (CVE-2026-98432) | `/etc/sysctl.d/99-no-mptcp.conf`, `/etc/nftables.d/cve-2026-98432.nft`, `/etc/systemd/system/cve-2026-98432.service` | both | `_docs` `platform/plans/archive/20261102-cve-2026-98432-tcp-mitigation/rollout.md` and its script | No; use the rollout's verify list |

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

## CloudFront address list

The RSVP, AMPAS and Guilds server blocks take the client address from `X-Forwarded-For` only
when one of CloudFront's origin-facing addresses made the connection. Every CloudFront
distribution reaches the origin from those addresses. Any other caller, including a direct-origin check, keeps its own
address, and a forged header changes nothing. The booking throttle and the API's booking checks
both key on that address.

The list lives in `nginx/includes/cloudfront-real-ip.conf`, generated from AWS's published
ranges. When AWS adds a range the list lacks, guests arriving through it share their edge's
address and can trip the booking throttle together. Check the list before each production
converge, and refresh it when the check fails:

```bash
scripts/update-cloudfront-ranges.py --check
scripts/update-cloudfront-ranges.py
```

Commit the refreshed file, then converge staging and production.

## Origin lockdown

The sites are meant to be reached only through CloudFront, where the WAF runs. The origin
hostnames (`origin.` and `origin.stg.`) and the static IPs answer anyone, so each CloudFront
distribution sends a secret `X-Origin-Auth` header to the origin, and nginx refuses any request
without it.

- **Secrets:** `/etc/amazon-server.origin-auth`, root 600, one secret per line: 32 to 40 letters
  and digits (a longer key overflows nginx's map hash and nginx won't start). `#` comments are
  allowed. Never in Git, chat or logs.
- **Converge** renders `/etc/nginx/includes/origin-auth.conf` (root 600) from that file
  (`infra/origin-auth.sh`). `includes/security.conf` then returns 403 to any request without a
  listed secret. Loopback still passes, keyed on the connecting address, so `smoke-all.sh` works
  and a forged `X-Forwarded-For` doesn't. Without the file, the repo's include refuses nothing:
  the local stack and an unconfigured host serve as before.
- **Status:** the `origin auth` line under manual checks gives the file's owner, mode, secret
  count, and whether nginx enforces it. It never prints a secret.

**Turn it on** (per environment, staging first). The header goes on before nginx checks it, so no
viewer ever sees a 403:

1. On the host: `sudo sh -c 'umask 077; LC_ALL=C tr -dc A-Za-z0-9 < /dev/urandom | head -c 40 > /etc/amazon-server.origin-auth.pending'`.
2. Add it as the origin custom header `X-Origin-Auth` on each of the environment's CloudFront
   distributions, read straight from that file. Wait for Deployed.
3. `sudo mv /etc/amazon-server.origin-auth.pending /etc/amazon-server.origin-auth`, then
   `sudo amazon-server-converge` and `status`.
4. Check: a request straight to the origin hostname gets 403; every site through CloudFront
   still answers as before.

**Rotate:** add the new secret as a second line and converge, switch the distributions' header to
it and wait for Deployed, then delete the old line and converge again.

**Turn it off:** delete the file and converge. The header on the distributions does no harm.

## Blocked agents and viewers

`nginx/includes/security.conf` returns 403 to every site, before any page or file is served, for
two lists in `nginx/nginx.conf`:

- `$blocked_agent`: user agents. Today only Amazon's DyePack scanner (`Chrome/51.0.2704.103`).
- `$blocked_viewer`: viewer addresses and ranges, listed with the reason for each in
  `nginx/includes/blocked-viewers.conf`. The check reads the viewer address that
  `cloudfront-real-ip.conf` sets, so it never blocks a CloudFront edge.

To block an address, add a line to `blocked-viewers.conf` with what it did and when, run `nginx -t`,
commit, and converge. A blocked request still reaches the origin through the CDN; it only stops
the page and its files from loading.

## Staging verification

Run the ratified must-serve matrix in
[`restructure-serving-surface.md`](../../_docs/rsvp/reference/restructure-serving-surface.md) against the static IP before
and after the origin switch. Compare against the **current landed local matrix capture** (the latest
`_artifacts/RS-*` final matrix), never a historical one — the hosted/direct page family 404s by
driver ruling 7 (2026-08-12), and API validation rules move with the code, so older baselines
report false failures. Use `--resolve` for direct-origin checks so the Host header remains the
staging name. The default origin policy uses port 80. Once the origin lockdown is on, a direct
check gets 403: run these before the secrets file is in place, or on the instance over loopback.

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
checks after the certificate-ready re-render. After the origin switch, repeat the same matrix
through the site names. Check status and response headers, not only bodies.

The live matrix, PHP-FPM startup, managed-database application login, certificate behavior, CDN
propagation, and browser smoke are driver checks after apply. Do not submit RSVPs or exercise any
email-sending path during this packet.

## Teardown

After an explicit driver decision, audit the instance against "Host state outside Git" and
point the `origin.` record back at the instance that stays first, then run:

```bash
terraform destroy
```

Never delete the instance or static IP in the Lightsail console: Terraform's state goes
stale, and a static IP left allocated but unattached keeps billing. Always destroy from
this directory.

Destroy removes the Terraform-managed Lightsail instance, public-port rules, static-IP attachment,
and static IP. It does not remove CDN distributions, their domains or certificates, DNS records,
managed databases, the driver's Lightsail key pair, or the local Terraform state file.
