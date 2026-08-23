# 2026.1 theme deploy branches

The 2026.1 AMPAS and Guilds themes deploy built assets through Git. The driver builds a theme
locally, pushes an orphan `deploy/<environment>-<timestamp>` branch, and applies that named branch
on the server. GitHub Actions remains an advisory merge gate and is not part of this path.

## Branch contract

Each deploy branch contains only the theme's real `web/app/themes/*2026.1/dist/` files:

- `dist/typescript/index.js`
- `dist/typescript/index.css`
- `dist/scss/style.css`
- `dist/Preview.[hash].js`

The deploy commit records the source branch, source commit, and UTC build time. The mutable remote
ref `deploy/live/<environment>` points at the deploy commit last applied to that environment. It is
a marker ref, not a second source branch.

## Prepare and apply

From the matching theme repository, build a deploy branch locally:

```bash
web/app/themes/cia-amazon-fyc-ampas-2026.1/scripts/deploy-theme.sh staging
git push origin deploy/staging-<timestamp>
```

Use the Guilds theme path for Guilds. The script returns to the source branch and prints the exact
push command. It warns before continuing with a dirty source tree and stops without a new branch
when the built `dist/` matches the newest remote deploy branch.

The source branch does not track `dist/`. The deploy branch is the durable copy of the build, so
run the theme build again before local rendering if branch switching leaves the ignored output
absent; this does not change the deploy branch.

On the server, apply the exact branch from the corresponding repository checkout:

```bash
_server/scripts/apply-theme-deploy.sh ampas staging deploy/staging-<timestamp>
_server/scripts/apply-theme-deploy.sh guilds staging deploy/staging-<timestamp>
```

The apply script:

1. Fetches the named deploy branch and rejects any commit that contains files outside its 2026.1
   `dist/` path.
2. Extracts the branch into a temporary directory, verifies every file hash, then replaces only
   that theme's `dist/` tree. Stale hashed chunks are removed by the replacement.
3. Runs the host wrapper at `_server/scripts/purge-theme-cache.sh`, which deletes only the
   `vm_titles_catalog` WordPress transients and fails if the site's database cannot be reached.
4. Pushes `deploy/live/<environment>` to the applied deploy commit.

The server checkout needs Git fetch access to the theme repository and write access for the mutable
`deploy/live/<environment>` marker ref. The script uses the deployed paths from `_docs/WORKSPACE.md`:

```text
AMPAS  /var/www/html/amazon-studios-ampas
Guilds /var/www/html/amazon-studios-guilds
```

The hosted purge command is explicit and reads `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
`DB_PASSWORD`, and `DB_PREFIX` from the deployed site's `.env`; matching keys in `.env.local`
override them. It uses the host's `mariadb` or `mysql` client, then falls back to PHP PDO MySQL
when the client is unavailable. The provisioned host has PHP 7.4 CLI and `php7.4-mysql`. No
database credential is printed or written to logs.

The apply script calls the purge hook without arguments. Set the site and wrapper for each apply:

```bash
THEME_DEPLOY_SITE=ampas \
THEME_DEPLOY_ENVIRONMENT=staging \
THEME_DEPLOY_PURGE_SCRIPT=/opt/amazon-server/scripts/purge-theme-cache.sh \
_server/scripts/apply-theme-deploy.sh ampas staging deploy/staging-<timestamp>
```

`THEME_DEPLOY_ENVIRONMENT` supplies the label in the purge result because the apply script calls
the hook without arguments. If it and `WP_ENV` are absent, the wrapper prints `unknown` rather
than guessing an environment; the database purge still uses the deployed site's config.

The direct wrapper form is also available for an operator check:

```bash
/opt/amazon-server/scripts/purge-theme-cache.sh ampas staging
```

For a scratch clone or a non-standard path, set `THEME_DEPLOY_REPO_DIR`; set
`THEME_DEPLOY_CONFIG_DIR` only when the checkout and its `.env` root differ. The environment label
is read from `WP_ENV` when the apply hook omits it. `THEME_DEPLOY_PURGE_SCRIPT` remains the escape
hatch for an exotic host command.

The local Docker harness's scratch checkout has no site `.env` because it is gitignored. Its
scratch proof may set `THEME_DEPLOY_LOCAL_DOCKER=1`; the wrapper then reads the running site's
MariaDB container environment. Hosted applies do not use this fallback.

Page-cache plugins are outside this wrapper's scope. `THEME_DEPLOY_PAGE_CACHE_PURGE_SCRIPT` is a
reserved hook name for the separate page-cache audit; the current apply path does not invoke it.

## What a dist deploy does NOT carry

The deploy branch holds only the theme's 2026.1 `dist/` tree, and the apply script rejects any
commit that reaches outside it. Everything else in the site repo — ACF field groups in
`acf-json/`, `functions/*.php`, templates — reaches the instance by updating its checkout:

```bash
cd /var/www/html/amazon-studios-<site>
git pull --ff-only origin develop
```

A change that lands PHP or ACF alongside built assets needs BOTH steps, or the site runs
mismatched halves — a new ACF field stays invisible in WP admin until the checkout pull
delivers its Local JSON (first hit: the Guilds cover-frame field, 2026-08-23). `dist/` is
gitignored, so the pull never disturbs an applied deploy. The instance deploy keys are
read-only: pulls work, pushes do not.

## Check status and clean up

From a theme repository, status fetches the live marker from `origin` and compares it with the
newest environment deploy branch:

```bash
web/app/themes/cia-amazon-fyc-ampas-2026.1/scripts/deploy-theme.sh status staging
```

`CURRENT` means the newest deploy branch is live. `GAP` means a newer deploy branch exists than the
live marker. `UNAPPLIED` means no live marker exists yet.

Keep the newest 30 environment branches on the remote:

```bash
web/app/themes/cia-amazon-fyc-ampas-2026.1/scripts/deploy-theme.sh prune staging
```

The marker ref is excluded from pruning. A rollback applies an earlier `deploy/<environment>-...`
branch, then moves the same live marker ref to that commit.

## Operations boundary

This is a driver-run workflow. It does not activate themes, change nginx, deploy the old rollback
themes, or require GitHub Actions. The first real staging apply follows review and is recorded by
the coordinator.
