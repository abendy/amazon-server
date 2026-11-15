# Reminder job alert (healthchecks.io)

The RSVP reminder job runs hourly on production and mails each attendee 20 to 24 hours before
their screening. If it stops, nothing on the site shows it: reminders just stop going out. A
healthchecks.io check emails the driver when the job stops pinging it or reports a failure.

## How it works

- After every run, the reminder wrapper pings the check's URL on exit 0, and `<url>/fail` on any
  other exit: a failed send, a log directory it cannot write, or a log it could not keep or prune
  (RSVP `docs/DEPLOYMENT.md`, "Outgoing mail").
- The cron line (`infra/cron/amazon-rsvp-reminders`) reads the URL at each run from
  `/etc/amazon-server.reminder-ping-url`. That file lives only on the instance. Without it, the
  job runs as before and pings nothing.
- healthchecks.io marks the check down, and emails you, when no ping arrives within the period
  plus the grace time, or as soon as a `/fail` ping arrives. It emails again when pings resume.
- `sudo amazon-server-converge status` reports the file on production: `ok`, or a `WARN` when it
  is missing, empty, or has the wrong owner or mode.

Anyone holding the URL can silence the alert. Keep it out of Git, chat, and shell history.

## Set up

### 1. Create the check

In healthchecks.io:

1. Add a check named `rsvp reminders (production)`.
2. Schedule: **Simple**, period **1 hour**, grace time **1 hour**. You then hear within about two
   hours of the last good run.
3. Integrations: make sure an **Email** integration with your address is on for this check.
4. Copy the check's ping URL. Don't paste it anywhere but the prompt in step 3.

### 2. Open a production shell

Production has no stored key. Fetch a temporary pair, per [`infra/README.md`](../infra/README.md),
"Instance access", with `--instance-name amazon-fyc-production`. The pair works for about five
minutes, but a session opened in that time stays open.

### 3. Install the URL

On the instance, as `ubuntu`. The hidden prompt keeps the URL out of shell history:

```bash
sudo install -o root -g www-data -m 0640 /dev/null /etc/amazon-server.reminder-ping-url
read -r -s -p 'Ping URL: ' ping_url; echo
printf '%s\n' "$ping_url" | sudo tee /etc/amazon-server.reminder-ping-url >/dev/null
unset ping_url
```

Check that the job's user can read it, without printing it:

```bash
sudo -u www-data test -r /etc/amazon-server.reminder-ping-url && echo readable
```

It prints `readable`.

### 4. Converge and check

```bash
sudo amazon-server-converge
grep -c REMINDER_PING_URL /etc/cron.d/amazon-rsvp-reminders
grep -c 'logger -t amazon-rsvp-reminders' /etc/cron.d/amazon-rsvp-reminders
sudo amazon-server-converge status | grep 'reminder ping'
```

- Both `grep -c` lines print `1`.
- The status line reads `ok    reminder ping`, then the file name and `root:www-data 640`. It
  never prints the URL.

Once the cron line is in place, a new or changed URL file takes effect at the next run, with no
converge.

### 5. Watch the first ping

The job runs at the top of each hour. After the next one:

- The check in healthchecks.io shows a ping and turns green.
- `journalctl -t amazon-rsvp-reminders --since -1h` shows nothing. A clean run writes no error
  lines; anything here is the wrapper's error output.

## Test the alert

Do this once after setup, and again after any change to the cron line or the wrapper.

1. Move the URL file aside. Runs go on, but stop pinging:

   ```bash
   sudo mv /etc/amazon-server.reminder-ping-url /root/reminder-ping-url
   ```

2. Wait one period plus the grace time. healthchecks.io emails you that the check is down.
3. Move the file back:

   ```bash
   sudo mv /root/reminder-ping-url /etc/amazon-server.reminder-ping-url
   ```

4. After the next run, the check turns green and healthchecks.io emails that it is back up.

## Replace or remove the URL

- **The URL leaked:** create a new check, install its URL with step 3, confirm a ping, then
  delete the old check.
- **Turn the alert off:** delete `/etc/amazon-server.reminder-ping-url`. The job keeps running,
  and `converge status` warns that the file is missing.

## Limits

- Production only. Staging has no reminder job, and `converge status` skips the check there.
- Only the reminder job is watched. The 15-minute confirmation job has no check.
- The alert says the job stopped or failed. To see which sends failed, read the run's log under
  `/var/www/html/rsvp/admin/application/logs/` and the RSVP `mail_log` table.
