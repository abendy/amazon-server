# IAM profiles

Each AWS job runs on its own IAM user and local CLI profile. One key never carries two concerns,
so a leaked or misused key reaches only its own job. Each profile has its own page under
[`iam/`](iam/): what it can do, its policy, and how to create and check it.

| Profile | Page | Job | Region |
| --- | --- | --- | --- |
| `amazon-lightsail-staging` | [terraform-staging.md](iam/terraform-staging.md) | Terraform for the Lightsail instance, static IP and ports; short-lived SSH access | `us-west-2` |
| `amazon-lightsail-backup` | [backup.md](iam/backup.md) | Read backup state; take instance and database snapshots | `us-west-2` |
| `amazon-gateway-deploy` | [gateway-deploy.md](iam/gateway-deploy.md) | Read the Indee gateway; deploy its one function and layer | `us-west-2` |
| `amazon-observability-read` | [observability-read.md](iam/observability-read.md) | Read metrics, costs, flat-rate plans, and the CloudFront and WAF logs | `us-east-1`, `us-west-2` |
| `amazon-cdn-move` | in `_docs`, `platform/plans/archive/20261123-cloudfront-pro-move/iam-policy.md` | The CloudFront distributions, WAF and DNS work from the CDN move | `us-east-1` |

## Rules for every profile

1. **One user, one group, one policy.** Attach the policy to a group named like the user, and
   put only that user in it. The group is the permission boundary.
2. **No console password.** Each user has one CLI access key and nothing else.
3. **Store keys without echoing them.** Use [`iam/access-keys.md`](iam/access-keys.md). Never put
   a key in Git, Terraform variables, tickets, transcripts or chat.
4. **Least privilege, named actions.** Policies list actions one by one, with no service-wide
   wildcard. Where AWS allows a resource ARN, the policy names it.
5. **Rotate or revoke** a key in IAM when its job ends.

## Choosing a profile

- Changing the Lightsail instance: `amazon-lightsail-staging`.
- Snapshot before a risky change: `amazon-lightsail-backup`.
- Gateway deploys: `amazon-gateway-deploy`.
- Traffic, load, cost, plan size, alarms input, or log questions: `amazon-observability-read`.
- CloudFront or WAF settings: `amazon-cdn-move`. It is the only key that reads distribution
  settings, which hold the origin secret.
