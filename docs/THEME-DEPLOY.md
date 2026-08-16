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
3. Runs the theme's existing `scripts/purge-titles-cache.sh`.
4. Pushes `deploy/live/<environment>` to the applied deploy commit.

The server checkout needs Git fetch access to the theme repository and write access for the mutable
`deploy/live/<environment>` marker ref. The script uses the deployed paths from `_docs/WORKSPACE.md`:

```text
AMPAS  /var/www/html/amazon-studios-ampas
Guilds /var/www/html/amazon-studios-guilds
```

For a scratch clone or a non-standard path, set `THEME_DEPLOY_REPO_DIR`. To use a host-specific
purge wrapper, set `THEME_DEPLOY_PURGE_SCRIPT` to that script before invoking the apply step.

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
