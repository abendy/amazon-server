# IAM for Lightsail staging Terraform

Create a dedicated IAM group and user for this module. The Terraform profile manages only the
Lightsail instance, static IP, attachment, and public ports in this directory. It does not manage
CDN distributions, DNS, managed databases, IAM, or application credentials.

The policy below names the AWS actions used by HashiCorp AWS provider `6.50.0` for this module:
instance/static-IP/public-port lifecycle calls, their operation and state reads, and tag updates.
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
        "lightsail:AttachStaticIp",
        "lightsail:CloseInstancePublicPorts",
        "lightsail:CreateInstances",
        "lightsail:DeleteInstance",
        "lightsail:DetachStaticIp",
        "lightsail:PutInstancePublicPorts",
        "lightsail:ReleaseStaticIp",
        "lightsail:TagResource",
        "lightsail:UntagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LightsailStagingRead",
      "Effect": "Allow",
      "Action": [
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
defines the action/resource limits. This policy deliberately contains no distribution, domain,
database, key-pair, or IAM actions.

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
