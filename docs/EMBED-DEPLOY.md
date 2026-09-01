# RSVP embed deploy — server side

The consideramazon Shadow DOM embed ships from the rsvp repository through an orphan deploy
branch; the build half is documented in the rsvp repo (`docs/DEPLOYMENT.md`). That document
defers the server-side apply to this runbook. First real production apply: 2026-09-01.

## Build and push (operator machine)

From the rsvp repository on `develop`:

```bash
./scripts/deploy-embed.sh consideramazon production external-css
git push origin deploy/production-<timestamp>
```

The `CUSTOMER` argument is mandatory — the bare `npm run build:embed` aliases fail with
`CUSTOMER environment variable is required`. `external-css` is the ruled production mode
(driver, 2026-09-01): component CSS and fonts ship as production-hosted files, not inlined.

## Apply (instance)

The branch holds only `dist/embed/consideramazon/`. Extract it into the served path:

```bash
cd /var/www/html/rsvp
git fetch origin deploy/production-<timestamp>
rm -rf public/consideramazon && mkdir -p public/consideramazon
git archive FETCH_HEAD dist/embed/consideramazon | tar -x --strip-components=3 -C public/consideramazon
```

nginx aliases `/rsvp/consideramazon/` to `public/consideramazon/`; the deployed files are
untracked there by design. Verify:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: rsvp.amazonmgmstudiosawards.com' \
  -H 'X-Forwarded-Proto: https' http://localhost/rsvp/consideramazon/rsvp.js
```

Expect 200 for `rsvp.js`, `rsvp.css`, `fonts.css`, and the `fonts/*.woff2` files.

## Traps

1. **The rsvp repository tracks `dist/`.** Never `rm -rf dist` in the server checkout as
   cleanup — that deletes committed files (bitten 2026-09-01; restored with
   `git checkout -- dist`). `node_modules` is safe to remove.
2. **Do not build on the instance.** On-instance vite builds write into the checkout and
   invert the deploy topology; the immutable branch is the artifact. Rollback = extract an
   earlier `deploy/<environment>-<timestamp>` branch the same way.
3. Staging uses the `external-css-staging` mode and the staging hostname; everything else is
   identical.
