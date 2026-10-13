# amazon-server

Serving configuration for the Amazon FYC sites — one nginx tree, three sites
(rsvp, AMPAS, Guilds), consumed two ways:

- **Locally:** each site's docker stack mounts this whole tree read-only from a
  clone at `_server/` beside the site repos.
- **Provisioned:** the co-located Lightsail instance installs this tree as its
  `/etc/nginx`, all three server blocks assembled.

## Layout

| Path | Holds |
|---|---|
| `nginx/nginx.conf` | The shared base config |
| `nginx/mime.types` | The shared deployed MIME table |
| `nginx/includes/` | Shared rules: security, static caching, gzip, fastcgi, WordPress |
| `nginx/server_blocks/` | One file per site — routing, docroots, site headers |
| `docs/ENV-DELTAS.md` | The exhaustive list of values that differ per environment |

Everything not in the env-delta list is byte-shared across local, staging, and
production. A difference outside that list is a bug.

**No secrets.** Certificates, `.htpasswd` contents, and credentials never enter this
repo — they are provisioner-owned and listed as env deltas.

## Local Docker stack

The local harness has one nginx container and one shared Docker network. The site repositories
provide the PHP-FPM and MySQL containers; this repository provides nginx and mounts the three
site docroots read-only.

Clone these repositories as siblings:

```text
amazon/
├── _db/
├── _server/
├── ampas/
├── guilds/
└── rsvp/
```

Create the external network once, then boot the site services before nginx:

```bash
docker network create amazon-local
docker compose -f ../rsvp/docker-compose.yml up -d
docker compose -f ../ampas/docker-compose.yml up -d
docker compose -f ../guilds/docker-compose.yml up -d
docker compose -f docker-compose.yml up -d
```

The network-create command is safe to repeat only after checking whether the network already
exists. The final command publishes port 80 and loads `localhost`, `ampas.local`, and
`guilds.local`. Use `curl --resolve <name>:80:127.0.0.1` for host-routed checks.

Each site's database runs `mysql:8.0.45`, the staging and production engine, and mounts
[`mysql/server-parity.cnf`](mysql/server-parity.cnf) for the servers' `sql_mode`, character set,
collation and time zone. Keep that file in step with the servers, never ahead of them.

Each WordPress MySQL service uses its own named volume (`ampas_mysql8_data`,
`guilds_mysql8_data`) and imports its matching `_db/` dump on first boot. The older
`*_mariadb_data` and `*_mysql_data` volumes are not referenced by these Compose files and must
not be removed.

WordPress logs in at `/wp/wp-login.php` (Bedrock layout); the root `/wp-login.php` returns 404.
A database restore can reset the active theme to an old rollback theme. After any restore,
confirm the 2026.1 themes are active before trusting what the sites show.

### Copying production data down

[`scripts/sync-data.py`](scripts/sync-data.py) copies the databases and uploads from production
(or staging) to the mini, staging, or both. It backs up every target first, never writes to
production, and copies RSVP's table structure without attendee rows. Run it with `--plan` to see
the steps; staging writes need `--yes`.

```bash
scripts/sync-data.py --from production --to local --plan
```

The local stack is a development harness only. It does not deploy or change the nginx serving
configuration on the mini or any hosted environment.

For laptop app containers against the mini's databases, follow the **Remote DB** sections in the [AMPAS README](../ampas/README.md), [Guilds README](../guilds/README.md), and [RSVP development guide](../rsvp/docs/DEVELOPMENT.md); use the published tailnet ports in [`docs/ENV-DELTAS.md`](docs/ENV-DELTAS.md), create `amazon-local`, start each site's FPM service with `docker compose up -d --no-deps <fpm service>`, and start this repository's nginx last.

## Lightsail staging

The co-located staging instance is described by the flat Terraform root in
[`infra/`](infra/). Read [`infra/README.md`](infra/README.md) before running the
driver-owned apply sequence. Terraform state, plan files, tfvars, and crash logs stay local.

## Provenance

Authored under the RSVP restructure track (RS-05+), translated from the deployed
instance configs snapshotted in the `_nginx` reference repo, archived on 2026-09-25 as
`_files/_nginx-legacy-2026-09-25.zip` at the workspace root with its local git history. Tracker: [abendy/amazon-docs](https://github.com/abendy/amazon-docs).
