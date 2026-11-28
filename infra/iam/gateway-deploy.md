# Gateway deploy profile: `amazon-gateway-deploy`

A separate profile reads how the Indee gateway is set up and deploys its function. The sites call
the gateway at `indeetv-watch.amazonmgmstudiosawards.com`, an API Gateway custom domain in
`us-west-2`. Neither the [Terraform](terraform-staging.md) nor the [backup](backup.md) profile can
reach API Gateway or Lambda, and neither should gain it: keep each concern behind its own key.

The gateway is one HTTP API in front of one Lambda function. A deploy changes the function: its
code, its runtime, or its layer. The API's routes and domain stay as they are, so the profile only
reads API Gateway.

Create this user in the AWS account that owns the gateway. That is the account whose API Gateway
console, in `us-west-2` under Custom domain names, lists the name above. It may not be the
Lightsail account.

## What this key can do

- Read the gateway's APIs, routes, integrations, stages and domain mappings.
- Read the one function's code and settings. **The code package carries a `.env` file that holds
  the upstream API key.** A key that can deploy the function downloads that package, so it can
  read that API key. Delete every downloaded copy of the `.env` file once a run ends.
- Replace the function's code, change its settings, and publish numbered versions of it.
- Publish and read versions of the function's one layer.

It cannot create or delete functions, change the function's role, change routes or domains, or
touch any other function. Every write changes the live gateway, so each one runs only on the
driver's go.

## Create the gateway deploy policy

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

## Create the gateway group, user, and profile

1. Create a group named `amazon-gateway-deploy` and attach the policy to it.
2. Create a user named `amazon-gateway-deploy` with no console password, in that group.
3. Create one CLI access key and store it with the [non-echoing form](access-keys.md), under
   the profile `amazon-gateway-deploy`.

Verify with read-only calls:

```bash
aws sts get-caller-identity --profile amazon-gateway-deploy
aws apigatewayv2 get-api-mappings --profile amazon-gateway-deploy --region us-west-2 \
  --domain-name indeetv-watch.amazonmgmstudiosawards.com
```

## Read the gateway

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
