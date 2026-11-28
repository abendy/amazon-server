# Indee gateway deploy

How the Indee gateway's code reaches AWS. The gateway is one Lambda function,
`AmazonStudiosIndeeTV`, behind one API Gateway HTTP API at
`indeetv-watch.amazonmgmstudiosawards.com`. The sites' Watch Now form posts a viewer's access code
to it. Its code lives in the `IndeeTV-API-Gateway` repository.

**There is one gateway.** Staging and production sites both call it. Every deploy is a production
change and runs only on the driver's go.

## What you need

- The `amazon-gateway-deploy` AWS profile on the operator machine. [`infra/iam/gateway-deploy.md`](../infra/iam/gateway-deploy.md)
  sets it up.
- A clone of the gateway repository, with the target commit pushed.
- `node` 22 or newer, `git`, `curl`, `unzip`, `openssl` and `python3`.

## Deploy

1. Land the change on the gateway repository's `develop`. Note the full commit SHA.
2. Read what the deploy would do. This changes nothing:

   ```bash
   scripts/deploy-gateway.sh plan <gateway-repo> <full-sha> develop
   ```

3. Get the driver's go. Then deploy:

   ```bash
   scripts/deploy-gateway.sh deploy <gateway-repo> <full-sha> develop
   ```

4. The driver plays a title through Watch Now with a real access code, on a staging site and a
   production site. The script cannot do this: it has no access code.
5. Record the two version numbers the script printed on the covering issue.

The script refuses a commit that is not the tip of the branch on origin, and a commit whose tests
fail. It exports that commit, so uncommitted files never ship.

## What the deploy does

| Step | Change | Safe because |
| --- | --- | --- |
| Package | Tests the commit's `function/` directory, zips its `index.js` and `gateway.js` | Nothing live changes |
| Rollback point | Publishes the running function as a numbered version | A version is a frozen copy of code and settings |
| `env` | Copies `API_URL` and `API_KEY` from the old package's `.env` into the function's environment | The old code ignores them |
| `limits` | Sets the timeout to 25 s and memory to 256 MB | The old code runs fine with more |
| `code` | Replaces the code, then checks the function reports the same package hash | The new code already has its settings |
| `layers` | Removes the layer | Only the old code used it |
| Smoke | Posts an empty body as a site's browser would. Expects the new code's `400` and a cross-origin header | No upstream call, no access code |

A step that is already done is skipped, so a second run of the same commit changes nothing. The
`env` and `layers` steps happen once, on the first deploy of the dependency-free code.

The smoke check proves the function runs, reads requests, and that browsers on the sites can read
its answers. The function sends no cross-origin header itself: the gateway's CORS settings add it,
and the smoke fails when they do not. It does not prove a login works. Step 4 above does.

## Roll back

A failed deploy prints the exact line to run. To roll back later, use the "rollback point" version
the deploy printed:

```bash
scripts/deploy-gateway.sh rollback <version>
```

It restores that version's runtime, handler, limits and layer first, then its code. It leaves the
environment values in place: both the old and the new code read them.

List the versions and what each holds:

```bash
aws lambda list-versions-by-function --profile amazon-gateway-deploy --region us-west-2 \
  --function-name AmazonStudiosIndeeTV --query 'Versions[].{v:Version,when:LastModified,what:Description}'
```

## Secrets

- The upstream API key lives in the function's environment. Every Lambda read of the function's
  settings returns it, so always pass a `--query` that leaves values out.
- The script moves values through files in a private scratch directory and deletes it on exit. It
  never prints one.
- Versions published before the first dependency-free deploy still carry the key in a `.env` file
  inside their package.

## What this does not cover

Gateway settings: allowed origins, the route, throttling, access logs and the default endpoint.
The deploy profile only reads API Gateway. Change those in the console, or widen the profile first.

## Test the script

```bash
scripts/tests/deploy-gateway.sh
```

It runs the script against a stand-in `aws` and `curl`. Nothing real is called.
