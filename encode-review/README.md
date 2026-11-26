# Encode review

A staging tool for trailers: upload a raw original, let the server encode it, compare the encode
with the original side by side, adjust and redo until it looks right, then approve it into Media.
From there it can replace an existing video in chosen fields and go to production Media as a
single file.

It runs on **staging only**, inside WordPress admin, for anyone who can upload files. Production
never runs it. No database or other content moves between sites.

| Part | Where |
|---|---|
| Admin page, **Media → Optimize video** | `wp-plugin/encode-review/`, a must-use plugin |
| Queue worker: encode, score, stills | `worker/`, Python 3 standard library, calling `ffmpeg` and `vmaf` |
| Service with its limits | `systemd/encode-review-worker.service` |
| nginx piece: playback | `nginx/encode-review.conf` |
| Installer | [`infra/encode-review.sh`](../infra/encode-review.sh), run by converge on staging |

## For content people

1. Open **Media → Optimize video** in staging WordPress (AMPAS or Guilds).
   Or start from a post: each ACF video field on the post edit screen has an **Encode a new
   version** link, which opens the tool with that post and field chosen (step 6).
2. **Upload an original**, up to 5 GB. Raw originals of 3–4 GB are normal. The browser sends it in
   parts of 64 MB, with progress and time left. If the connection drops, it sends the part again
   by itself and then offers **Resume upload**; nothing already sent goes again. After a reload or
   a crash, choose the same file again and it picks up where it stopped. Unfinished uploads are
   listed under the form and deleted 7 days after their last part. The encoder checks that the
   file is a video. It does not go into Media yet. The upload needs the rest of its size free on
   the server above the 10 GB reserve; the server says so when it starts or resumes if not. A file
   that arrived whole while the disk was too full to queue it waits in the list ("waiting for disk
   space"): once space is back, choose the same file again and it joins the queue without sending
   anything again.
3. **Wait in the queue.** One video encodes at a time. The list shows each video's stage, how many
   are ahead, and a time estimate. A 2–3 minute trailer takes roughly 10–20 minutes. You can leave
   the page and come back.
4. **Compare.** When it is ready, the page plays the original and the encode side by side, in step.
   When the original is in a format browsers do not reliably play (ProRes, 10-bit, and the like),
   the server makes a **reference copy** first: a near-lossless H.264 copy at the original's size
   and frame rate, labelled "Reference copy" on the page. The quality scores and the stills still
   compare against the original itself. If the server has no room for the copy, or making it
   fails, the attempt stops with that reason and the original is kept: the job cannot be approved
   until **Redo** (or a fresh upload) makes the copy.
   - **Wipe** stacks them and lets you slide between the two.
   - **Swap sides** and **Hide names** let you judge without knowing which is which.
   - **Worst moments** jumps to the 2-second stretches that scored lowest. The stills show the worst
     frames, original on the left.
   - The numbers show size, bitrate and quality scores (VMAF, 0–100). The advice box shows the
     rule of thumb from past trailers: at least 15% smaller and a VMAF mean of 90 or more. It is
     advice only. **You decide by eye.**
5. **Adjust and redo** if it does not look right. Lower quality numbers (CRF) look better and make
   bigger files; 21 is the usual start. The bitrate cap limits the busiest scenes. Every attempt
   stays on the page, and you can compare any two.
6. **Approve** the attempt you want. It becomes a normal file in this site's Media, named after
   the original (`.mp4`). Once Media has the whole file, the original and every attempt are
   **deleted from the server**: to redo it later, upload the master again (from Vimeo). If Media
   refuses the file, nothing is deleted. The page opens the approved video's own page, which
   **Approved videos** on the main page lists too. A video started from a post's **Encode a new
   version** link also replaces the old video in that one field, if it still holds the video it
   held at upload; the message says what changed. No other field changes.
7. **Use in place of…** (optional), on the approved video's page. Pick the video this one replaces. The page lists every field
   that uses the old video. Tick the ones to change, check the list again, and confirm. Only the
   ticked fields change, and only on staging. Fields on posts you cannot edit are listed without
   a tick box and never change; the swap checks that permission for each post as it writes.
8. **Send to production** (optional), on the approved video's page. Sends this one file to production Media. Nothing else goes:
   no posts and no fields. In production, pick the file in the field by hand, as today. A file is
   sent once. If production refuses it or cannot be reached, the page says so and you can send
   again. If the upload is cut off midway, the page says it is not sure the file arrived; the
   encoder then looks for it in production Media (about 15 minutes later, once production has
   finished anything still running) and shows it as sent, or lets you send again. It never sends
   twice on its own.

Approving deletes a job's original and attempts. Jobs never approved are deleted 7 days after
their last activity. Approved files stay in Media.

## How it works

```text
admin page (PHP-FPM, www-data)            worker (systemd, encode-review user)
  upload in 64 MiB parts ─► incoming/<id>/
  last part ─► /srv/encode-review/queue/<job>/ ─► claims one job into work/
                                                  reference copy, if no browser plays the original
                                                  ffmpeg encode (x264, 2 threads)
                                                  ffmpeg ─y4m─► vmaf (1 thread, every 2nd frame)
                                                  stills of the worst moments
  review ◄─ done/<job>/attempts/<n>/        ◄─ results.json in job.json
  playback: login check, then X-Accel-Redirect to nginx's internal /_encode-review/
  redo ─► back to queue/ with new settings
  approve ─► media_handle_sideload() into staging Media, check the file, delete the job
  send ─► sends/<site>-<attachment>/ ─────────► POST /wp-json/wp/v2/media on production
                                                (lookup by token when the outcome is unknown)
```

- **Spool** `/srv/encode-review/`: `incoming/ queue/ work/ done/ failed/`, one folder per job with
  `job.json`, and `sends/`, one record per attachment sent to production. Both sides take
  `state.lock` around every move and every `job.json` or `record.json` write. The worker holds
  `run.lock` while it runs, so only one encode ever runs. `status.json` is the worker's
  heartbeat, rewritten every 20 seconds by its own thread, also during an encode; the page shows
  "The encoder is not running" when it is 2 minutes old.
- **Uploads** go in parts. `encode_review_upload_start` (admin-post.php) checks the 5 GiB cap and
  the floor and creates `incoming/<id>/` with `upload.json` and `original.<ext>.part`; the same
  person's unfinished upload of the same file (name, size, modification time) is resumed instead.
  Each `encode_review_upload_part` request carries up to 64 MiB as its raw body, with the offset
  in the URL. Under the upload's own lock the server drops anything past the confirmed bytes (a
  part cut off mid-write), appends the part, and answers with its new count. A part it already
  holds (a resend after a lost answer) is acknowledged without writing; a part at any other offset
  gets a 409 with the count to resume from. When the count reaches the announced size, the file is
  renamed, `job.json` is written and the folder moves to `queue/` under `state.lock`: only then
  can the worker see it. If the floor refuses that last step, every byte stays in `incoming/`; a
  resume finds the count equal to the size and sends an empty part at the end, which asks again.
  The browser checks only the 5 GiB cap itself: free space is the server's call, since only it
  knows how many bytes of a resumed file it already holds. Each request is a few seconds at most, well inside CloudFront's 30-second
  origin wait, and fits the sites' own limits (nginx 600 MB, PHP 512 MB): the tool needs no
  limit of its own. There is no type rule: the encoder's probe refuses anything that is not a
  video.
- **Reference copy:** when the probe says no browser plays the original (anything but H.264,
  VP8/9 or AV1 in 8-bit 4:2:0 with AAC, MP3, Opus, Vorbis or FLAC sound in a fitting container),
  the worker first makes `reference.mp4`: `libx264 -preset veryfast -crf 12`, `yuv420p`, the
  original's size and frame rate, AAC 192k, faststart, capped at 1.5 bits per pixel per frame. It
  is made once per job, kept across redos and deleted with the job. It is made only when its
  largest possible size still leaves the 10 GiB floor free. Refused or failed, the attempt fails
  before its encode with the reason (also kept as `reference_error`), the job moves to `failed/`
  with the original kept, and both the page and the approve handler refuse approval while the copy
  is missing; a redo tries the copy again. VMAF and the stills use the original.
- **Field entry:** on the post edit screen, each ACF file field holding a video gets a link to
  `upload.php?page=encode-review&for=<post>&key=<meta key>`. The upload records that target
  (post, meta key, the video it held) after checking the person may edit the post; it stays in
  `job.json` through the queue and redos. Approve swaps that one field only if it still holds that
  video, through the same check as "Use in place of…". That shared swap checks `edit_post` for
  each chosen post at the write, whichever page called it, and reports the fields it left alone.
- **Encode preset** (from the #553 trial): `libx264 -preset slow -crf 21`, cap 5 Mbit/s up to
  1080p and 3 Mbit/s up to 720p, buffer always 4× the cap, high profile, level 4.1 or 3.1,
  `yuv420p`, AAC 128k stereo, first video and audio stream only, `+faststart`. People change only
  the CRF (18–26) and the cap (1–12 Mbit/s).
- **Checks per attempt:** VMAF mean, minimum and 1st percentile; the five worst non-overlapping
  2-second windows; faststart (`moov` before `mdat`); duration within 0.2 s.
- **Scoring tool:** Ubuntu 24.04's `ffmpeg` has no `libvmaf` filter, so the installer adds
  Netflix's official `vmaf` release build (pinned version, SHA-256 checked) at
  `/opt/encode-review/bin/vmaf`.
- **Limits** (systemd): `MemoryMax=800M`, `MemorySwapMax=0` (the swap file is MySQL's guard),
  `CPUQuota=150%`, `Nice=19`, `IOSchedulingClass=idle`. needrestart leaves the worker alone after
  unattended upgrades, so a library update never cuts off an encode.
- **Disk floor:** every new encode attempt needs 10 GiB free on the spool's disk. An upload's
  start counts its whole size, one part's temporary copy and what other unfinished uploads still
  have to send; each part counts what is left. The check runs again under `state.lock` at the
  moment the job joins the queue (a complete upload refused there waits in `incoming/` until a
  resent last part queues it), and for every redo; a refused redo leaves the job and its attempts
  as they were. The reference copy has its own check (above).
- **Retention:** approving deletes the job (original and attempts) as soon as Media holds the
  whole file: the attachment exists and its file has the encode's exact size. A refused or
  unconfirmed insert deletes nothing. The worker deletes jobs never approved, and unfinished
  uploads (by `upload.json`'s last part), once they are idle for 7 days, checked hourly. Send
  records stay; only
  their file copies go.
- **Sends** run on a helper thread, so they never wait behind an encode. The worker, not PHP,
  holds the production login. Each staging attachment has one record,
  `sends/<site>-<attachment ID>/record.json`, created under `state.lock`, so two clicks start one
  send. The worker writes `sending` before the upload. A refusal (4xx) or a connection that never
  opened is `failed`, and a person may send again. A timeout, a dropped connection, a 5xx, or a
  worker stop during the upload is `unknown`: never sent again on its own. Each try writes a token
  into the production attachment's description; 15 minutes after an unknown try (production's PHP
  stops every request within 10), the worker searches production Media for the token. Found is
  `sent`; not found is `failed`. If production cannot be searched, it retries every 5 minutes.

## Operators

Converge installs and checks everything on staging (`infra/README.md`, "Encode review tool").

```bash
sudo amazon-server-converge
sudo amazon-server-converge status
```

The `encode review` status group checks the service, whether it runs the checked-out code, unit
and login, its limits, the spool, `ffmpeg` and `vmaf`, the plugin in both sites, free disk, and
whether the production login is in place.

Useful commands on staging:

```bash
systemctl status encode-review-worker
journalctl -u encode-review-worker -n 50
sudo ls /srv/encode-review/queue /srv/encode-review/work /srv/encode-review/done
systemctl show encode-review-worker -p MemoryPeak -p CPUUsageNSec
```

To run one job by hand, stop the service and run the worker once as its user:
`sudo -u encode-review python3 /opt/amazon-server/encode-review/worker/run.py --once`.

If a send stays `unknown` because production cannot be searched, look in production Media for the
attachment whose description holds the token shown in `record.json`, then settle it by hand:

```bash
sudo cat /srv/encode-review/sends/<site>-<staging attachment ID>/record.json
sudo -u encode-review python3 /opt/amazon-server/encode-review/worker/run.py \
  --resolve-send <site>-<staging attachment ID> --production-id <production attachment ID>
sudo -u encode-review python3 /opt/amazon-server/encode-review/worker/run.py \
  --resolve-send <site>-<staging attachment ID> --absent
```

## Send to production: driver steps

Production gets no code. Three one-time steps, per production site (AMPAS and Guilds), in this
order.

1. **Create the upload-only role** on the production host, once per site. It is stored in the
   site's database and grants only `read` and `upload_files`, so the user can add media and
   nothing else (built-in Author could also write posts). Production installs Composer packages
   without dev tools, so WP-CLI is not there; fetch the pinned release, check it, use it, delete it:

   ```bash
   cd /tmp
   curl -fsSLO https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar
   echo 'be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832  wp-cli-2.12.0.phar' | sha512sum --check
   for site in amazon-studios-ampas amazon-studios-guilds; do
     sudo -u www-data php /tmp/wp-cli-2.12.0.phar --path="/var/www/html/${site}/web/wp" role create upload_only 'Upload only'
     sudo -u www-data php /tmp/wp-cli-2.12.0.phar --path="/var/www/html/${site}/web/wp" cap add upload_only read upload_files
     sudo -u www-data php /tmp/wp-cli-2.12.0.phar --path="/var/www/html/${site}/web/wp" cap list upload_only
   done
   rm /tmp/wp-cli-2.12.0.phar
   ```

   Each `cap list` must print exactly `read` and `upload_files`.

2. **Create the upload user and its application password** in each production WordPress admin:
   **Users → Add New**, role **Upload only**; then on that user's profile, **Application
   Passwords**, name it `staging encode review`, and copy the password once.

3. **Store the login on staging**, root-only, then converge:

   ```bash
   sudo install -m 600 /dev/null /root/amazon-staging/encode-review-production.env
   sudo editor /root/amazon-staging/encode-review-production.env
   sudo amazon-server-converge
   ```

   The file holds one block per site. Leave out a site to keep its button off.

   ```text
   AMPAS_URL=https://<production AMPAS host>
   AMPAS_USER=<upload user login>
   AMPAS_APP_PASSWORD=<application password>
   GUILDS_URL=https://<production Guilds host>
   GUILDS_USER=<upload user login>
   GUILDS_APP_PASSWORD=<application password>
   ```

   Converge hands the file to the worker through systemd's credential store
   (`LoadCredential=`). PHP-FPM cannot read it. Status shows `production login present`.

To revoke, delete the application password in production admin. To rotate, create a new one,
edit the file and converge: converge restarts the worker whenever the file's contents change, so
the new password takes effect at once.

The send record in the spool is what went where (production attachment ID, URL, who and when, and
every try). A finished send is also copied onto the staging attachment (`_encode_review_send`).
