# IAM for Lightsail Terraform, backups, the Indee gateway and metrics reads

Create a dedicated IAM group and user for this module. The Terraform profile manages only the
Lightsail instance, static IP, attachment, and public ports in this directory. Terraform does not
manage CDN distributions, DNS, managed databases, IAM, or application credentials.

The same profile also carries a few operator actions on the CDN distributions, outside Terraform:
reading distributions, certificates, and distribution metrics, changing cache behaviors, and
resetting the cache. The CLI is the reliable way to change cache behaviors, because the Lightsail
console can drop path rules and the query-string allow-list on save.

The policy below names the AWS actions used by HashiCorp AWS provider `6.50.0` for this module:
instance/static-IP/public-port lifecycle calls, their operation and state reads, and tag updates.
It adds the distribution actions above.
`sts:GetCallerIdentity` lets the provider establish the caller account during configuration. No
service-wide action wildcard is present. AWS requires `Resource: "*"` for the create actions and
for these Lightsail reads; the action list is the least-privilege boundary for this profile.

## 1. Create the policy

As an IAM administrator, open IAM → Policies → Create policy → JSON and paste this document. Use a
name such as `amazon-lightsail-staging-terraform`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LightsailStagingLifecycle",
      "Effect": "Allow",
      "Action": [
        "lightsail:AllocateStaticIp",
        "lightsail:AttachCertificateToDistribution",
        "lightsail:AttachStaticIp",
        "lightsail:CloseInstancePublicPorts",
        "lightsail:CreateInstances",
        "lightsail:DeleteInstance",
        "lightsail:DetachStaticIp",
        "lightsail:PutInstancePublicPorts",
        "lightsail:ReleaseStaticIp",
        "lightsail:ResetDistributionCache",
        "lightsail:TagResource",
        "lightsail:UntagResource",
        "lightsail:UpdateDistribution"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LightsailStagingRead",
      "Effect": "Allow",
      "Action": [
        "lightsail:GetCertificates",
        "lightsail:GetDistributions",
        "lightsail:GetDistributionMetricData",
        "lightsail:GetInstance",
        "lightsail:GetInstanceAccessDetails",
        "lightsail:GetInstancePortStates",
        "lightsail:GetOperation",
        "lightsail:GetStaticIp"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TerraformCallerIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

The action set follows the provider's [Lightsail instance resource](https://github.com/hashicorp/terraform-provider-aws/blob/v6.50.0/internal/service/lightsail/instance.go),
[public-port resource](https://github.com/hashicorp/terraform-provider-aws/blob/v6.50.0/internal/service/lightsail/instance_public_ports.go),
[static-IP resource](https://github.com/hashicorp/terraform-provider-aws/blob/v6.50.0/internal/service/lightsail/static_ip.go),
and [attachment resource](https://github.com/hashicorp/terraform-provider-aws/blob/v6.50.0/internal/service/lightsail/static_ip_attachment.go).
AWS's [Lightsail authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonlightsail.html)
defines the action/resource limits. The distribution actions cover operator CDN work only: no
action creates or deletes a distribution. The policy contains no domain, database, key-pair, or
IAM actions.

`lightsail:GetInstanceAccessDetails` is not a Terraform action: it issues the short-lived SSH
key-and-certificate pairs used for post-apply instance access (see the "Instance access" section
of [`README.md`](README.md)). Fetch both halves of a pair from a single call — pairs from
different calls do not match.

## 2. Create the group and user

As the IAM administrator:

1. Create a group named `amazon-lightsail-staging-terraform`.
2. Attach the new customer-managed policy to that group.
3. Create a user named `amazon-lightsail-staging-terraform` with no console password.
4. Add the user to the group.

The group is the permission boundary. Attach the policy to the group, not to an unrelated personal
user.

## 3. Create and store the access key

From the new user's Security credentials tab, create one access key for a local CLI tool. Copy the
secret access key once. It cannot be retrieved later. Do not paste either key into Git, Terraform
variables, shell transcripts, tickets, or chat.

Configure a named profile on the driver's mini:

```bash
aws configure --profile amazon-lightsail-staging
chmod 600 ~/.aws/credentials
```

Store the access key ID and secret access key in the prompted profile in `~/.aws/credentials`. Set
the driver-selected default region when prompted. Terraform uses it with:

```bash
export AWS_PROFILE=amazon-lightsail-staging
```

Verify identity before the first Terraform plan. This is a read-only AWS call:

```bash
aws sts get-caller-identity --profile amazon-lightsail-staging
```

Rotate or revoke the access key through IAM when the staging work ends. This packet does not add
IAM resources to Terraform or store any account-specific value.

## Entering the access key safely

`aws configure --profile <name>` echoes both key values into the terminal — they land in
scrollback (and any multiplexer history). Prefer the non-echoing form:

```bash
aws configure set aws_access_key_id <ID> --profile <name>
aws configure set aws_secret_access_key <SECRET> --profile <name>
```

If the interactive form was already used, clear the pane history afterwards (e.g.
`tmux clear-history -t <session>`) and rotate the key if the screen was shared.

## Backup profile

A second, separate profile checks and takes backups. The Terraform profile above cannot read
databases or snapshots, and it should not gain them: keep instance lifecycle and backups behind
different keys.

### What Lightsail backs up on its own

- **Instances:** the automatic-snapshot add-on takes a daily snapshot and keeps the last seven.
  It is set per instance and is off until someone enables it in the console (instance →
  Snapshots → Automatic snapshots). Neither profile can enable it. Check each instance with
  `aws lightsail get-auto-snapshots --profile amazon-lightsail-backup --region us-west-2
  --resource-name <instance>`: an empty `autoSnapshots` list means the add-on is off.
- **Managed databases:** no scheduled snapshots exist. Point-in-time backup is on by default and
  restores any point in the last seven days to a **new** database. After a restore, point each
  site's `.env` at the new endpoint by hand.
- **Manual snapshots** of either kind persist and bill until deleted. Take one before a risky
  change; this profile cannot delete them, so prune in the console.

### Create the backup policy

As an IAM administrator, open IAM → Policies → Create policy → JSON and paste this document. Use a
name such as `amazon-lightsail-backup`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LightsailBackupRead",
      "Effect": "Allow",
      "Action": [
        "lightsail:GetAutoSnapshots",
        "lightsail:GetInstanceSnapshot",
        "lightsail:GetInstanceSnapshots",
        "lightsail:GetRelationalDatabase",
        "lightsail:GetRelationalDatabases",
        "lightsail:GetRelationalDatabaseSnapshot",
        "lightsail:GetRelationalDatabaseSnapshots",
        "lightsail:GetOperation",
        "lightsail:GetOperations",
        "lightsail:GetOperationsForResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LightsailBackupCreate",
      "Effect": "Allow",
      "Action": [
        "lightsail:CreateInstanceSnapshot",
        "lightsail:CreateRelationalDatabaseSnapshot"
      ],
      "Resource": "*"
    }
  ]
}
```

The policy reads backup state and creates snapshots, nothing more. It holds no delete, update,
restore, or add-on actions. `EnableAddOn` is left out on purpose: it also sets
`StopInstanceOnIdle`, which can stop a serving instance. `GetRelationalDatabase` returns the
`backupRetentionEnabled` flag (point-in-time backup on or off) but not the master password, which
needs a separate action this policy omits. Restores stay a console act by the driver.

### Create the backup group, user, and profile

1. Create a group named `amazon-lightsail-backup` and attach the policy to it.
2. Create a user named `amazon-lightsail-backup` with no console password, in that group.
3. Create one CLI access key and store it with the non-echoing form above, under the profile
   `amazon-lightsail-backup`.

Verify with read-only calls:

```bash
aws sts get-caller-identity --profile amazon-lightsail-backup
aws lightsail get-relational-databases --profile amazon-lightsail-backup --region us-west-2 \
  --query 'relationalDatabases[].{name:name,pointInTime:backupRetentionEnabled,latestRestorable:latestRestorableTime}'
```

### Take a snapshot before a risky change

Use this profile. The Terraform profile is denied `CreateInstanceSnapshot` and
`GetInstanceSnapshot` by design. Name snapshots `<resource>-<reason>-<UTC timestamp>` so the
console list sorts and explains itself. Wait for each one to finish before the change starts:

```bash
stamp="$(date -u +%Y%m%d-%H%M%S)"
aws lightsail create-instance-snapshot --profile amazon-lightsail-backup --region us-west-2 \
  --instance-name <instance> --instance-snapshot-name "<instance>-<reason>-${stamp}"
aws lightsail create-relational-database-snapshot --profile amazon-lightsail-backup \
  --region us-west-2 --relational-database-name <database> \
  --relational-database-snapshot-name "<database>-<reason>-${stamp}"
aws lightsail get-instance-snapshot --profile amazon-lightsail-backup --region us-west-2 \
  --instance-snapshot-name "<instance>-<reason>-${stamp}" --query 'instanceSnapshot.state'
aws lightsail get-relational-database-snapshot --profile amazon-lightsail-backup \
  --region us-west-2 --relational-database-snapshot-name "<database>-<reason>-${stamp}" \
  --query 'relationalDatabaseSnapshot.state'
```

Proceed only when both states read `available`. Record the snapshot names in the run's report.

## Gateway deploy profile

A third, separate profile reads how the Indee gateway is set up and deploys its function. The
sites call the gateway at `indeetv-watch.amazonmgmstudiosawards.com`, an API Gateway custom domain
in `us-west-2`. Neither profile above can reach API Gateway or Lambda, and neither should gain
it: keep each concern behind its own key.

The gateway is one HTTP API in front of one Lambda function. A deploy changes the function: its
code, its runtime, or its layer. The API's routes and domain stay as they are, so the profile only
reads API Gateway.

Create this user in the AWS account that owns the gateway. That is the account whose API Gateway
console, in `us-west-2` under Custom domain names, lists the name above. It may not be the
Lightsail account.

### What this key can do

- Read the gateway's APIs, routes, integrations, stages and domain mappings.
- Read the one function's code and settings. **The code package carries a `.env` file that holds
  the upstream API key.** A key that can deploy the function downloads that package, so it can
  read that API key. Delete every downloaded copy of the `.env` file once a run ends.
- Replace the function's code, change its settings, and publish numbered versions of it.
- Publish and read versions of the function's one layer.

It cannot create or delete functions, change the function's role, change routes or domains, or
touch any other function. Every write changes the live gateway, so each one runs only on the
driver's go.

### Create the gateway deploy policy

As an IAM administrator, open IAM → Policies → Create policy → JSON and paste this document. Use a
name such as `amazon-gateway-deploy`. Replace `<account-id>` with the 12-digit ID of the account that owns the gateway.

The policy names the function the gateway invokes, `AmazonStudiosIndeeTV`, and its one layer,
`AmazonStudiosIndeeTV-Node`. The API's Integrations page and the function's Layers list show both.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GatewayRead",
      "Effect": "Allow",
      "Action": "apigateway:GET",
      "Resource": [
        "arn:aws:apigateway:us-west-2::/apis",
        "arn:aws:apigateway:us-west-2::/apis/*",
        "arn:aws:apigateway:us-west-2::/domainnames",
        "arn:aws:apigateway:us-west-2::/domainnames/*"
      ]
    },
    {
      "Sid": "GatewayFunctionDeploy",
      "Effect": "Allow",
      "Action": [
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:GetRuntimeManagementConfig",
        "lambda:ListVersionsByFunction",
        "lambda:PublishVersion",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration"
      ],
      "Resource": [
        "arn:aws:lambda:us-west-2:<account-id>:function:AmazonStudiosIndeeTV",
        "arn:aws:lambda:us-west-2:<account-id>:function:AmazonStudiosIndeeTV:*"
      ]
    },
    {
      "Sid": "GatewayLayerDeploy",
      "Effect": "Allow",
      "Action": [
        "lambda:GetLayerVersion",
        "lambda:ListLayerVersions",
        "lambda:PublishLayerVersion"
      ],
      "Resource": [
        "arn:aws:lambda:us-west-2:<account-id>:layer:AmazonStudiosIndeeTV-Node",
        "arn:aws:lambda:us-west-2:<account-id>:layer:AmazonStudiosIndeeTV-Node:*"
      ]
    }
  ]
}
```

Each statement and why it is there:

- `GatewayRead` reads HTTP APIs in one region. An integration names the function the gateway
  invokes. Stage variables are readable too, so keep secrets out of them.
- `GatewayFunctionDeploy` covers one function and its numbered versions. `GetFunction` returns a
  download link for the live code, which is how a deploy saves a copy to roll back to.
  `GetRuntimeManagementConfig` reads whether the runtime follows AWS's patches or is pinned.
  `PublishVersion` freezes the current code and settings under a number before a change.
- `GatewayLayerDeploy` covers one layer, which holds the function's Node packages. Attaching a
  layer version to the function needs `GetLayerVersion` on that version.

The policy holds no `iam:PassRole`, so the function's role cannot change, and no
`lambda:ListFunctions`, which would return every function's environment values. AWS defines the
actions and resource paths in the
[API Gateway V2](https://docs.aws.amazon.com/service-authorization/latest/reference/list_apigatewayv2.html)
and [Lambda](https://docs.aws.amazon.com/service-authorization/latest/reference/list_awslambda.html)
authorization references.

### Create the gateway group, user, and profile

1. Create a group named `amazon-gateway-deploy` and attach the policy to it.
2. Create a user named `amazon-gateway-deploy` with no console password, in that group.
3. Create one CLI access key and store it with the non-echoing form above, under the profile
   `amazon-gateway-deploy`.

Verify with read-only calls:

```bash
aws sts get-caller-identity --profile amazon-gateway-deploy
aws apigatewayv2 get-api-mappings --profile amazon-gateway-deploy --region us-west-2 \
  --domain-name indeetv-watch.amazonmgmstudiosawards.com
```

### Read the gateway

The mapping gives the API ID. The integration gives the function:

```bash
aws apigatewayv2 get-integrations --profile amazon-gateway-deploy --region us-west-2 \
  --api-id <ApiId> --query 'Items[].{type:IntegrationType,uri:IntegrationUri}'
aws apigatewayv2 get-routes --profile amazon-gateway-deploy --region us-west-2 \
  --api-id <ApiId> --query 'Items[].RouteKey'
```

This prints the function's runtime and the names of its environment variables, never their
values:

```bash
aws lambda get-function-configuration --profile amazon-gateway-deploy --region us-west-2 \
  --function-name AmazonStudiosIndeeTV \
  --query '{Runtime:Runtime,Handler:Handler,PackageType:PackageType,LastModified:LastModified,RuntimeVersion:RuntimeVersionConfig,Layers:Layers[].Arn,EnvNames:keys(Environment.Variables||`{}`)}'
```

This prints whether the runtime follows AWS's patches (`Auto`) or is pinned (`Manual`):

```bash
aws lambda get-runtime-management-config --profile amazon-gateway-deploy --region us-west-2 \
  --function-name AmazonStudiosIndeeTV --query 'UpdateRuntimeOn'
```

Always pass a `--query` that leaves the values out, on every Lambda read and write: the update
calls answer with the full settings too. The CLI filters after the full answer arrives, so the
values still reach the machine. The query only keeps them off the screen and out of logs.

## Read-only metrics profile

One key that reads what cost and load work needs and changes nothing: Lightsail inventory and
metrics (instances, managed databases, CDN distributions, disks, snapshots), CloudWatch metrics
and alarms, CloudFront distribution settings, Cost Explorer, and the `fyc-*` CloudFront and WAF
log groups. It is separate from the Terraform, backup and gateway keys.

It is narrower than AWS's `ReadOnlyAccess`, which would also read every S3 object and other
clients' resources in the account. It cannot read database passwords, S3 objects or secrets.

### Create the read-only policy

Create a customer managed policy named `amazon-fyc-read-metrics`. Lightsail, CloudWatch and Cost
Explorer reads accept only `Resource: "*"`; the action list is the boundary. Log reads are limited
to the move plan's log groups.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LightsailInventoryAndMetrics",
      "Effect": "Allow",
      "Action": [
        "lightsail:GetAutoSnapshots",
        "lightsail:GetDisks",
        "lightsail:GetDistributionBundles",
        "lightsail:GetDistributionMetricData",
        "lightsail:GetDistributions",
        "lightsail:GetDomains",
        "lightsail:GetInstanceMetricData",
        "lightsail:GetInstanceSnapshots",
        "lightsail:GetInstances",
        "lightsail:GetRelationalDatabaseMetricData",
        "lightsail:GetRelationalDatabaseSnapshots",
        "lightsail:GetRelationalDatabases",
        "lightsail:GetStaticIps"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchAndCloudFrontReads",
      "Effect": "Allow",
      "Action": [
        "cloudfront:GetDistribution",
        "cloudfront:GetDistributionConfig",
        "cloudfront:ListDistributions",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CostExplorerReads",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetCostForecast",
        "ce:GetDimensionValues"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ListLogGroups",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:GetQueryResults",
        "logs:StopQuery"
      ],
      "Resource": "*"
    },
    {
      "Sid": "QueryFycLogs",
      "Effect": "Allow",
      "Action": [
        "logs:FilterLogEvents",
        "logs:StartQuery"
      ],
      "Resource": [
        "arn:aws:logs:us-east-1:*:log-group:fyc-*",
        "arn:aws:logs:us-east-1:*:log-group:aws-waf-logs-fyc-*"
      ]
    },
    {
      "Sid": "CallerIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

### Create the read-only group, user, and profile

1. Create a group named `amazon-fyc-readonly` and attach the policy to it.
2. Create a user named `amazon-fyc-readonly` with no console password, in that group.
3. Create one CLI access key and store it with the non-echoing form above, under the profile
   `amazon-fyc-readonly`.

Verify with read-only calls:

```bash
aws sts get-caller-identity --profile amazon-fyc-readonly
aws lightsail get-relational-database-metric-data --profile amazon-fyc-readonly --region us-west-2 \
  --relational-database-name <database-name> --metric-name CPUUtilization --period 3600 \
  --start-time "$(date -u -d '-1 day' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --unit Percent --statistics Average Maximum
```
