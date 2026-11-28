# Metrics, costs and logs profile: `amazon-observability-read`

One key that reads load, traffic, cost and logs, and changes nothing. Cost, plan-size and alarm
work runs on it. It is separate from the Terraform, backup, gateway and CDN keys.

## What this key can do

- **Metrics:** CloudWatch metrics, alarms and dashboards. That covers CloudFront requests and
  bytes per distribution, WAF allowed and blocked counts per rule, and anything else in
  CloudWatch.
- **Lightsail load:** instance and managed-database metrics (CPU, burst capacity, connections),
  plus the inventory and bundle sizes needed to read them.
- **Costs:** Cost Explorer cost, usage and forecasts, and existing budgets.
- **Plans:** which CloudFront flat-rate plan each distribution is on.
- **Logs:** Logs Insights queries and event reads on the CloudFront access-log groups (`fyc-*`)
  and the WAF log groups (`aws-waf-logs-fyc-*`), in `us-east-1`.
- **WAF:** the web ACLs' rules, sampled requests, logging setup and the addresses a rate rule is
  limiting right now.
- **Alert routing:** SNS topics and their subscriptions, so an alarm's target can be checked.

## What it cannot do

- Change anything. The policy holds no create, update, delete or put action.
- **Read CloudFront distribution settings.** `GetDistribution`, `GetDistributionConfig` and
  `ListDistributions` return each origin's custom headers, and the origin lockdown's
  `X-Origin-Auth` secret is one of them (see [`../README.md`](../README.md), "Origin lockdown").
  The distribution IDs are all a metrics read needs.
- Read S3 objects, secrets, SSM parameters, database passwords or IAM. AWS's `ReadOnlyAccess`
  policy reads several of these, so this profile does not use it.
- Read log groups other than the two prefixes above.
- Read a flat-rate plan's usage against its allowance. AWS has no API for that: the CloudFront
  console and the 50%, 80% and 100% emails show it. See "Reading plan usage" below.

## Before you create it

Cost Explorer answers IAM users only after the account's root user turns on **IAM user and role
access to Billing information** (Account → IAM user and role access to Billing information →
Edit). Without it, every `ce:` call is denied even with this policy.

## Create the policy

As an IAM administrator, open IAM → Policies → Create policy → JSON and paste this document.
Name it `amazon-observability-read`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:DescribeAlarmHistory",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:GetDashboard",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListDashboards",
        "cloudwatch:ListMetrics"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LightsailLoad",
      "Effect": "Allow",
      "Action": [
        "lightsail:GetBundles",
        "lightsail:GetDisks",
        "lightsail:GetInstanceMetricData",
        "lightsail:GetInstances",
        "lightsail:GetRelationalDatabaseBundles",
        "lightsail:GetRelationalDatabaseMetricData",
        "lightsail:GetRelationalDatabases",
        "lightsail:GetStaticIps"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Costs",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetCostForecast",
        "ce:GetDimensionValues",
        "ce:GetTags",
        "ce:GetUsageForecast"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Budgets",
      "Effect": "Allow",
      "Action": [
        "budgets:DescribeBudgetActionsForBudget",
        "budgets:ViewBudget"
      ],
      "Resource": "arn:aws:budgets::*:budget/*"
    },
    {
      "Sid": "FlatRatePlans",
      "Effect": "Allow",
      "Action": [
        "cloudfront:GetMonitoringSubscription",
        "pricingplanmanager:GetSubscription",
        "pricingplanmanager:ListSubscriptions"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LogsAnyGroup",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeDeliveries",
        "logs:DescribeDeliveryDestinations",
        "logs:DescribeDeliverySources",
        "logs:DescribeLogGroups",
        "logs:DescribeQueries",
        "logs:GetQueryResults",
        "logs:StopQuery"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LogsFycGroups",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogStreams",
        "logs:FilterLogEvents",
        "logs:GetLogEvents",
        "logs:StartQuery"
      ],
      "Resource": [
        "arn:aws:logs:us-east-1:*:log-group:fyc-*",
        "arn:aws:logs:us-east-1:*:log-group:aws-waf-logs-fyc-*"
      ]
    },
    {
      "Sid": "WafList",
      "Effect": "Allow",
      "Action": "wafv2:ListWebACLs",
      "Resource": "*"
    },
    {
      "Sid": "WafFycAcls",
      "Effect": "Allow",
      "Action": [
        "wafv2:GetLoggingConfiguration",
        "wafv2:GetRateBasedStatementManagedKeys",
        "wafv2:GetSampledRequests",
        "wafv2:GetWebACL"
      ],
      "Resource": "arn:aws:wafv2:us-east-1:*:global/webacl/fyc-*/*"
    },
    {
      "Sid": "AlertRouting",
      "Effect": "Allow",
      "Action": [
        "sns:ListSubscriptionsByTopic",
        "sns:ListTopics"
      ],
      "Resource": "*"
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

Why each statement is there:

- `CloudWatchMetrics`, `Costs`, `FlatRatePlans`, `WafList` and `AlertRouting` use actions that
  AWS defines without a resource type, or reads that the whole account needs. The action list is
  the boundary.
- `LightsailLoad` reads sizes and load. `GetRelationalDatabases` returns each database's user
  name but not its password, which needs an action this policy leaves out.
- `Budgets` reads budgets and their actions. Creating budgets and alarms needs a separate,
  write-scoped key.
- `LogsFycGroups` limits queries and reads to the two log-group prefixes. The pattern also covers
  each group's streams.
- `WafFycAcls` limits rule and sample reads to the `fyc-*` web ACLs. Sampled requests and rate
  keys hold viewer addresses: keep their output out of tickets and chat.

AWS defines the actions in the authorization references for
[CloudWatch](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cloudwatch.html),
[CloudWatch Logs](https://docs.aws.amazon.com/service-authorization/latest/reference/list_logs.html),
[Lightsail](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonlightsail.html),
[Cost Explorer](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ce.html),
[Budgets](https://docs.aws.amazon.com/service-authorization/latest/reference/list_budgets.html),
[Pricing Plan Manager](https://docs.aws.amazon.com/service-authorization/latest/reference/list_pricing-plan-manager.html),
[WAF V2](https://docs.aws.amazon.com/service-authorization/latest/reference/list_wafv2.html) and
[SNS](https://docs.aws.amazon.com/service-authorization/latest/reference/list_sns.html).

## Create the group, user, and profile

1. Create a group named `amazon-observability-read` and attach the policy to it.
2. Create a user named `amazon-observability-read` with no console password, in that group.
3. Create one CLI access key and store it with the [non-echoing form](access-keys.md), under
   the profile `amazon-observability-read`.

## Verify

Each call below is read-only. Run them in order. The first three prove identity, metrics and
logs; the last two need the billing access above.

```bash
aws sts get-caller-identity --profile amazon-observability-read
aws cloudwatch list-metrics --profile amazon-observability-read --region us-east-1 \
  --namespace AWS/CloudFront --metric-name Requests --query 'length(Metrics)'
aws logs describe-log-groups --profile amazon-observability-read --region us-east-1 \
  --log-group-name-prefix fyc- --query 'logGroups[].logGroupName'
aws ce get-cost-and-usage --profile amazon-observability-read --region us-east-1 \
  --time-period "Start=$(date -u +%Y-%m-01),End=$(date -u -d tomorrow +%F)" \
  --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
aws lightsail get-relational-database-metric-data --profile amazon-observability-read \
  --region us-west-2 --relational-database-name <database-name> --metric-name CPUUtilization \
  --period 3600 --start-time "$(date -u -d '-1 day' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --unit Percent --statistics Average Maximum
```

## Reading plan usage

No API returns a flat-rate plan's usage against its allowance. Read it from the web ACL's
`AllowedRequests` in `us-east-1`, summed since the 1st of the month:

- Requests the WAF blocks don't count against the allowance.
- CloudFront's own `Requests` metric counts them anyway: it equals `AllowedRequests` plus
  `BlockedRequests`. Don't use it for the allowance.

```bash
aws cloudwatch get-metric-statistics --profile amazon-observability-read --region us-east-1 \
  --namespace AWS/WAFV2 --metric-name AllowedRequests --statistics Sum --period 86400 \
  --dimensions Name=WebACL,Value=<acl-name> Name=Rule,Value=ALL \
  --start-time "$(date -u +%Y-%m-01)T00:00:00Z" --end-time "$(date -u +%FT%TZ)"
```

A plan's allowance is per distribution. Each site has its own distribution, web ACL and plan.
This lists them, with each plan's tier and start date:

```bash
aws pricing-plan-manager list-subscriptions --profile amazon-observability-read --region us-east-1
```

A plan started mid-month is billed for the days left. The first month's allowance appears to
shrink the same way: AWS's 50% email for a Pro plan started on the 25th came at about 1M counted
requests, not 5M.
