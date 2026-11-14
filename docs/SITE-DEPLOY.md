# Site deploys

Three scripts move a host's site checkouts to one reviewed commit and check the result. Run each
from this repo on the operator machine. It streams to the host over SSH and runs there as
`ubuntu`, using `sudo`:

```bash
ssh <host> 'bash -s -- <args>' < scripts/<script>
```

Production access uses a temporary key (`infra/README.md`, "Instance access").

| Script | Moves | Arguments |
|---|---|---|
| [`scripts/deploy-rsvp.sh`](../scripts/deploy-rsvp.sh) | The RSVP checkout, `/var/www/html/rsvp` | `<target-full-sha> <master\|develop> [applied-migration-dir ...]` |
| [`scripts/deploy-wp.sh`](../scripts/deploy-wp.sh) | One WordPress root checkout: core, plugins and Composer packages | `<ampas\|guilds> <target-full-sha> <master\|develop> [repair]` |
| [`scripts/smoke-all.sh`](../scripts/smoke-all.sh) | Nothing: it reads | `<staging\|production> "<YYYY/MM/DD HH:MM UTC since>"` |

The 2026.1 theme files ship separately, through deploy branches ([`THEME-DEPLOY.md`](THEME-DEPLOY.md)),
and so does the RSVP embed ([`EMBED-DEPLOY.md`](EMBED-DEPLOY.md)).

## What the deploy scripts guarantee

Both deploy scripts:

- take the full 40-character SHA and refuse it unless `origin/<branch>` points at it and it
  descends from the deployed commit;
- refuse a checkout with local changes, and change nothing;
- print a **rollback point** (the commit they started from) before they change anything;
- fast-forward only, then hand root-owned files back to `ubuntu` and verify the checkout is clean;
- stop at the first failure and print the next step. Re-running the same command is the recovery
  path.

`deploy-rsvp.sh` also refuses a range that adds files under `scripts/migrations/` until each of
those migration directories is applied by hand (rsvp `docs/DEPLOYMENT.md`, "Database Migrations")
and named after the branch argument.

`deploy-wp.sh` also downloads every Composer package into a scratch copy first, so an auth or
network failure stops before the live site changes. It then swaps the code, runs the WordPress
database upgrade, and checks that `db_version` matches core. After any failed run, re-run with
`repair`: it force-reinstalls every installed package, core included.

## Release order

Per host, staging first, then production on the driver's go:

1. `_server`: move the environment's branch, then `sudo amazon-server-converge` and `status`
   (`infra/README.md`, "Converge and status").
2. RSVP: apply the range's migrations by hand, then `deploy-rsvp.sh <sha> <branch> <dir> ...`.
3. AMPAS and Guilds: `deploy-wp.sh <site> <sha> <branch>`, one site at a time.
4. Themes: apply each site's deploy branch (`THEME-DEPLOY.md`).
5. `smoke-all.sh <environment> "<UTC time step 1 started>"`. Any failure is a stop.

Record each printed rollback point on the covering issue.

## Rollback

Never rewind or force-push a branch. A rollback ends as a new commit that the branch reaches by
fast-forward.

1. **Code.** Check out the rollback point as root:
   `sudo git -c safe.directory=<dir> -C <dir> checkout --detach <rollback point>`. For WordPress,
   then run the root Composer install and the `chown` that `deploy-wp.sh` uses. Reconcile later
   with revert commits, or fix forward; the checkout stays detached until then.
2. **WordPress database.** A core upgrade's schema change can't be undone in code. Use the managed
   database's point-in-time restore to the time before the deploy; it creates a new database, so
   the site's `.env` `DB_HOST` moves to it, then FPM restarts. Writes after the restore point are
   lost.
3. **Last resort.** An instance snapshot (`infra/README.md`, "OS patches").
