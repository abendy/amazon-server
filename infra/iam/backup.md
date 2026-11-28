# Backup profile: `amazon-lightsail-backup`

A separate profile checks and takes backups. The [Terraform profile](terraform-staging.md) cannot
read databases or snapshots, and it should not gain them: keep instance lifecycle and backups behind
different keys.

## What Lightsail backs up on its own

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

## Create the backup policy

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

## Create the backup group, user, and profile

1. Create a group named `amazon-lightsail-backup` and attach the policy to it.
2. Create a user named `amazon-lightsail-backup` with no console password, in that group.
3. Create one CLI access key and store it with the [non-echoing form](access-keys.md), under
   the profile `amazon-lightsail-backup`.

Verify with read-only calls:

```bash
aws sts get-caller-identity --profile amazon-lightsail-backup
aws lightsail get-relational-databases --profile amazon-lightsail-backup --region us-west-2 \
  --query 'relationalDatabases[].{name:name,pointInTime:backupRetentionEnabled,latestRestorable:latestRestorableTime}'
```

## Take a snapshot before a risky change

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
