# Lightsail staging

This root module describes the one co-located Ubuntu 24.04 Lightsail staging instance for RSVP,
AMPAS, and Guilds. Terraform owns the instance, static IPv4 address, attachment, and public ports.
Existing Lightsail CDN distributions, their domains and certificates, and the managed databases are
driver-owned and stay outside Terraform.

## Ground rules

1. **This repo must stay public.** The instance bootstrap clones it anonymously over
   HTTPS; a private repo means every fresh instance boots unprovisioned. The no-secrets
   rule is therefore existential, not hygiene.
2. **Run Terraform from the mini's clone**, in this directory, with the branch that
   carries `infra/` checked out (`develop` once RS-07 lands). The state file lives here
   and only here.
3. **Provision from landed `develop`.** The bootstrap clones the branch in the
   `server_branch` variable (default `develop`) and provisioner re-runs follow the same
   branch. Land serving-tree and `infra/` changes before creating a real staging
   instance; set `server_branch` only for a deliberate pre-land test build. On an
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
never propose replacing staging. Every post-apply manual step below applies unchanged; the
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

### Recover a failed first boot

When the bootstrap cloned a branch that lacks `infra/` (see ground rule 3),
`/var/log/cloud-init-output.log` ends with
`bash: /opt/amazon-server/infra/cloud-init.sh: No such file or directory`. Fix it over
temporary SSH — check out the branch that carries `infra/`, then run the provisioner:

```bash
ssh -i ls-temp-key ubuntu@<static-ip> \
  'sudo git -C /opt/amazon-server fetch --depth 1 origin <branch> &&
   sudo git -C /opt/amazon-server checkout FETCH_HEAD &&
   sudo bash /opt/amazon-server/infra/cloud-init.sh'
```

The provisioner's self-update resets the checkout to `develop` mid-run; that is by
design and does not affect the run already in flight.

## Post-apply manual steps

Complete these steps on the new instance before changing a CDN origin. The cloud-init script is
safe to re-run from `/usr/local/sbin/amazon-staging-provision`; it re-renders the installed nginx
tree and ends with its own `nginx -t` gate.

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

**WordPress dependencies (AMPAS and Guilds).** cloud-init installs `unzip` and
Composer (phar installer — never `apt install composer`, which installs a second,
newer PHP alongside 7.4). Run `composer install --no-dev --no-interaction` at each WP
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
WP_ENV=staging  WP_HOME=https://<stg-host>  WP_SITEURL=${WP_HOME}/wp
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

### 4. Keep the staging-only nginx values manual

Supply the driver-approved CSP host list and embed password on the instance. Their contents never
enter Terraform or Git.

```bash
sudoedit /etc/nginx/snippets/rsvp-staging-csp.conf
sudo nginx -t
sudo systemctl reload nginx

sudo htpasswd -c /etc/nginx/.htpasswd <staging-user>
sudo chmod 600 /etc/nginx/.htpasswd
sudo nginx -t
sudo systemctl reload nginx
```

### 5. Flip the existing CDN origins

Cutover is an origin change on the existing distributions, not a DNS change:

1. Record each distribution's current origin for rollback.
2. Set each distribution's origin to the new instance's `static_ip` output using the driver's
   existing Lightsail distribution workflow.
3. Keep the distribution domains and certificates unchanged, and wait for the distribution to
   finish propagating.
4. Run the public serving matrix below through the distribution hostnames.

Rollback is the same operation in reverse: restore each recorded old origin. Terraform does not
manage or modify any distribution.

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

After an explicit driver decision, restore the recorded CDN origins first, then run:

```bash
terraform destroy
```

Never delete the instance or static IP in the Lightsail console: Terraform's state goes
stale, and a static IP left allocated but unattached keeps billing. Always destroy from
this directory.

Destroy removes the Terraform-managed Lightsail instance, public-port rules, static-IP attachment,
and static IP. It does not remove CDN distributions, their domains or certificates, DNS records,
managed databases, the driver's Lightsail key pair, or the local Terraform state file.
