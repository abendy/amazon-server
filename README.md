# amazon-server

Serving configuration for the Amazon FYC sites — one nginx tree, three sites
(rsvp, AMPAS, Guilds), consumed two ways:

- **Locally:** each site's docker stack mounts the shared base plus its own server
  block from this repo (cloned as `_server/` beside the site repos).
- **Provisioned:** the co-located Lightsail instance installs this tree as its
  `/etc/nginx`, all three server blocks assembled.

## Layout

| Path | Holds |
|---|---|
| `nginx/nginx.conf` | The shared base config |
| `nginx/includes/` | Shared rules: security, static caching, gzip, fastcgi, WordPress |
| `nginx/server_blocks/` | One file per site — routing, docroots, site headers |
| `docs/ENV-DELTAS.md` | The exhaustive list of values that differ per environment |

Everything not in the env-delta list is byte-shared across local, staging, and
production. A difference outside that list is a bug.

**No secrets.** Certificates, `.htpasswd` contents, and credentials never enter this
repo — they are provisioner-owned and listed as env deltas.

## Provenance

Authored under the RSVP restructure track (RS-05+), translated from the deployed
instance configs snapshotted in the `_nginx` reference repo (to be archived after
the R5 cutover). Tracker: [abendy/amazon-docs](https://github.com/abendy/amazon-docs).
