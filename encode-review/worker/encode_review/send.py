"""Send to production: one approved file into production Media, nothing else.

Every staging attachment has at most one send record, the folder
``sends/<site>-<attachment id>/`` with ``record.json`` (and, while a send is
open, ``file.mp4``, a copy of the attachment). WordPress creates the record
under ``state.lock``, so two clicks cannot both start a send. The record is
the one durable decision about that attachment; the 7-day cleanup removes
only its file copy, never the record.

States (``record["state"]``):

    queued   WordPress asked for a send; the worker has not started it
    sending  the worker is uploading; it writes this before the POST
    sent     production answered with the new attachment (or a lookup found it)
    failed   known not to be in production: refused, unreachable, or a lookup
             after an unknown outcome found nothing. Sending again is allowed.
    unknown  the upload was cut off after it may have reached production (a
             timeout, a dropped connection, a 5xx, or a worker stop during
             "sending"). Never sent again until a lookup settles it.

Each try carries a unique token in the attachment's description. After an
unknown outcome the worker waits until any request still running on
production must have ended (``SETTLE_S``, longer than production's 600 s PHP
limit), then searches production Media for the token: found means sent, not
found means failed. Only then may a person send again.

The login comes from systemd's credential store (``LoadCredential=``), read
from a root-only file on staging. PHP-FPM never sees it.
"""

from __future__ import annotations

import base64
import json
import os
import re
import secrets
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from .spool import Spool, now, read_json, write_json

CREDENTIAL_NAME = "production-upload"
SITES = ("ampas", "guilds")
TIMEOUT_S = 600
RECORD = "record.json"
PAYLOAD = "file.mp4"
# Seconds after an unknown try before the lookup counts: production's PHP
# stops any request after 600 s (max_execution_time), plus a margin.
SETTLE_S = int(os.environ.get("ENCODE_REVIEW_SEND_SETTLE_S", "900"))
RECHECK_S = 300


def credentials_file() -> Path | None:
    folder = os.environ.get("CREDENTIALS_DIRECTORY")
    return Path(folder) / CREDENTIAL_NAME if folder else None


def parse_env(text: str) -> dict[str, str]:
    """KEY=value lines; blank lines and # comments are skipped, quotes stripped."""
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def site_login(site: str, path: Path | None = None) -> dict[str, str] | None:
    """The production URL, user and application password for a site, or None."""
    path = path or credentials_file()
    if path is None or not path.is_file():
        return None
    values = parse_env(path.read_text())
    prefix = site.upper()
    login = {
        "url": values.get(f"{prefix}_URL", "").rstrip("/"),
        "user": values.get(f"{prefix}_USER", ""),
        "password": values.get(f"{prefix}_APP_PASSWORD", ""),
    }
    return login if all(login.values()) else None


def configured_sites(path: Path | None = None) -> dict[str, bool]:
    return {site: site_login(site, path) is not None for site in SITES}


def safe_filename(name: str) -> str:
    """A filename safe for a Content-Disposition header."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-.")
    return cleaned or "video.mp4"


def auth_header(login: dict[str, str]) -> str:
    return "Basic " + base64.b64encode(f"{login['user']}:{login['password']}".encode()).decode()


def description(token: str) -> str:
    return f"Sent from staging by encode review ({token})."


def upload(login: dict[str, str], file_path: Path, filename: str, mime: str,
           title: str | None, token: str) -> dict[str, Any]:
    """Streams one file to production Media. Returns the new attachment's id and URL.

    The title and description ride in the query string: the upload-only role
    may create media but not edit it afterwards.
    """
    fields = {"title": title, "description": description(token)} if title else {
        "description": description(token)}
    size = file_path.stat().st_size
    with file_path.open("rb") as body:
        request = urllib.request.Request(
            f"{login['url']}/wp-json/wp/v2/media?{urllib.parse.urlencode(fields)}",
            data=body,
            method="POST",
            headers={
                "Authorization": auth_header(login),
                "Content-Type": mime,
                "Content-Disposition": f'attachment; filename="{safe_filename(filename)}"',
                "Content-Length": str(size),
                "User-Agent": "encode-review-worker",
            },
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:  # noqa: S310
            created = json.loads(response.read().decode())
    return {"production_id": int(created["id"]), "production_url": created.get("source_url", "")}


def lookup(login: dict[str, str], token: str) -> dict[str, Any] | None:
    """Searches production Media for the attachment a try created, by its token."""
    query = urllib.parse.urlencode({"search": token, "per_page": 10, "er_check": now()})
    request = urllib.request.Request(
        f"{login['url']}/wp-json/wp/v2/media?{query}",
        headers={"Authorization": auth_header(login), "User-Agent": "encode-review-worker",
                 "Cache-Control": "no-cache"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310
        items = json.loads(response.read().decode())
    if not isinstance(items, list):
        raise ValueError("Production did not answer with a list of media.")
    for item in items:
        if isinstance(item, dict) and token in json.dumps(item):
            return {"production_id": int(item["id"]), "production_url": item.get("source_url", "")}
    return None


def describe_error(error: BaseException) -> str:
    if isinstance(error, urllib.error.HTTPError):
        detail = ""
        try:
            body = json.loads(error.read().decode() or "{}")
            detail = body.get("message", "") if isinstance(body, dict) else ""
        except (ValueError, OSError):
            pass
        finally:
            error.close()
        return f"Production answered {error.code}{': ' + detail if detail else ''}"
    if isinstance(error, urllib.error.URLError):
        return f"Could not reach production: {error.reason}"
    return str(error) or error.__class__.__name__


def never_reached(error: BaseException) -> bool:
    """True when the error proves production never received the upload.

    Production answered with a refusal (4xx), or the connection failed before
    any byte went out (no such host, connection refused, a bad certificate).
    Anything else (a timeout, a dropped connection, a 5xx from the CDN while
    the origin may still be working) leaves the outcome unknown.
    """
    if isinstance(error, urllib.error.HTTPError):
        return 400 <= error.code < 500
    if isinstance(error, urllib.error.URLError):
        reason = error.reason
        return isinstance(reason, (socket.gaierror, ConnectionRefusedError,
                                   ssl.SSLCertVerificationError))
    return False


# ---- records ------------------------------------------------------------------


def sends_dir(spool: Spool) -> Path:
    return spool.path("sends")


def record_dirs(spool: Spool) -> list[Path]:
    folder = sends_dir(spool)
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir()
                  if p.is_dir() and not p.name.startswith(".") and (p / RECORD).is_file())


def load(folder: Path) -> dict[str, Any]:
    return read_json(folder / RECORD)


def save(folder: Path, record: dict[str, Any]) -> None:
    """Rewrites record.json. Call under state_lock."""
    record["updated_at"] = now()
    write_json(folder / RECORD, record)


def current_try(record: dict[str, Any]) -> dict[str, Any]:
    tries = record.get("tries") or []
    if not tries:
        raise ValueError("The send record has no try.")
    return tries[-1]


def drop_payload(folder: Path) -> None:
    payload = folder / PAYLOAD
    if payload.exists():
        payload.unlink()


def pending_sends(spool: Spool) -> list[Path]:
    """Records waiting for the worker to upload them, oldest request first."""
    waiting: list[tuple[int, Path]] = []
    for folder in record_dirs(spool):
        try:
            record = load(folder)
            if record.get("state") == "queued":
                waiting.append((int(current_try(record).get("requested_at", 0)), folder))
        except (OSError, ValueError):
            continue
    return [folder for _, folder in sorted(waiting)]


def due_checks(spool: Spool, at: int | None = None) -> list[Path]:
    """Unknown records whose lookup is due."""
    at = now() if at is None else at
    due: list[Path] = []
    for folder in record_dirs(spool):
        try:
            record = load(folder)
        except (OSError, ValueError):
            continue
        if record.get("state") == "unknown" and int(record.get("check_after", 0)) <= at:
            due.append(folder)
    return due


def recover_interrupted(spool: Spool) -> list[str]:
    """Marks sends a stopped worker left in "sending" as unknown. Never resends them."""
    recovered: list[str] = []
    with spool.state_lock():
        for folder in record_dirs(spool):
            try:
                record = load(folder)
            except (OSError, ValueError):
                continue
            if record.get("state") != "sending":
                continue
            attempt = current_try(record)
            mark_unknown(record, attempt, "The worker stopped during the upload.")
            save(folder, record)
            recovered.append(folder.name)
    return recovered


def mark_unknown(record: dict[str, Any], attempt: dict[str, Any], error: str) -> None:
    started = int(attempt.get("started_at") or now())
    record["state"] = "unknown"
    record["check_after"] = started + SETTLE_S
    attempt.update(outcome="unknown", error=error, finished_at=now())


def mark_sent(record: dict[str, Any], attempt: dict[str, Any], found: dict[str, Any],
              host: str, how: str) -> None:
    record.update(state="sent", production_id=found["production_id"],
                  production_url=found.get("production_url", ""), production_host=host,
                  sent_at=now())
    record.pop("check_after", None)
    attempt.update(outcome="sent" if how == "upload" else "found", finished_at=now(),
                   production_id=found["production_id"])


def process_send(spool: Spool, folder: Path, credentials: Path | None = None) -> dict[str, Any]:
    """Uploads one queued send and records how it ended. Returns the record."""
    with spool.state_lock():
        record = load(folder)
        if record.get("state") != "queued":
            return record
        attempt = current_try(record)
        record["state"] = "sending"
        attempt["started_at"] = now()
        save(folder, record)

    site = str(record.get("site", ""))
    login = site_login(site, credentials)
    payload = folder / PAYLOAD
    error: BaseException | None = None
    created: dict[str, Any] | None = None
    if login is None:
        error = RuntimeError(f"Send to production is not set up for {site}.")
    elif not payload.is_file():
        error = RuntimeError("The file to send is missing. Send again.")
    else:
        try:
            created = upload(login, payload, str(record.get("filename")),
                             str(record.get("mime", "video/mp4")), record.get("title"),
                             str(attempt["token"]))
        except (urllib.error.URLError, OSError, ValueError, KeyError) as caught:
            error = caught

    with spool.state_lock():
        record = load(folder)
        attempt = current_try(record)
        if created is not None and login is not None:
            mark_sent(record, attempt, created, login["url"], "upload")
            drop_payload(folder)
        elif error is not None and (login is None or not payload.is_file()
                                    or never_reached(error)):
            record["state"] = "failed"
            attempt.update(outcome="failed", error=describe_error(error), finished_at=now())
            drop_payload(folder)
        else:
            mark_unknown(record, attempt, describe_error(error) if error else "No answer.")
        save(folder, record)
    return record


def check_send(spool: Spool, folder: Path, credentials: Path | None = None) -> dict[str, Any]:
    """Looks up an unknown send on production and settles it when it can."""
    with spool.state_lock():
        record = load(folder)
    if record.get("state") != "unknown":
        return record
    site = str(record.get("site", ""))
    login = site_login(site, credentials)
    attempt = current_try(record)
    found: dict[str, Any] | None = None
    problem = ""
    if login is None:
        problem = f"Send to production is not set up for {site}."
    else:
        try:
            found = lookup(login, str(attempt["token"]))
        except (urllib.error.URLError, OSError, ValueError, KeyError) as caught:
            problem = describe_error(caught)

    with spool.state_lock():
        record = load(folder)
        if record.get("state") != "unknown":
            return record
        attempt = current_try(record)
        record["checked_at"] = now()
        if problem:
            record["check_error"] = problem
            record["check_after"] = now() + RECHECK_S
        elif found is not None and login is not None:
            record.pop("check_error", None)
            mark_sent(record, attempt, found, login["url"], "lookup")
            drop_payload(folder)
        else:
            record.pop("check_error", None)
            record.pop("check_after", None)
            record["state"] = "failed"
            attempt.update(outcome="failed", finished_at=now(),
                           error=f"{attempt.get('error') or 'The upload was cut off'}. "
                                 "Production Media does not have the file, so it can be "
                                 "sent again.")
            drop_payload(folder)
        save(folder, record)
    return record


def resolve(spool: Spool, key: str, production_id: int | None) -> dict[str, Any]:
    """Operator override for an unknown send: found in production, or not there.

    For when the automatic lookup cannot reach production. Settles the record
    the same way a lookup would.
    """
    folder = sends_dir(spool) / key
    with spool.state_lock():
        record = load(folder)
        if record.get("state") != "unknown":
            raise ValueError(f"{key} is {record.get('state')}, not unknown.")
        attempt = current_try(record)
        record["checked_at"] = now()
        record.pop("check_error", None)
        if production_id:
            mark_sent(record, attempt, {"production_id": production_id}, "", "operator")
        else:
            record.pop("check_after", None)
            record["state"] = "failed"
            attempt.update(outcome="failed", finished_at=now(),
                           error="An operator confirmed production Media does not have the "
                                 "file, so it can be sent again.")
        drop_payload(folder)
        save(folder, record)
    return record


def new_token(site: str, attachment_id: int, n: int) -> str:
    """The token one try writes into the production description (tests and docs)."""
    return f"er-{site}-{attachment_id}-{n}-{secrets.token_hex(4)}"
