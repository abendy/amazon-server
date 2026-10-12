#!/usr/bin/env python3
"""Copy site data down from production or staging to the mini and/or staging.

    sync-data.py --from production --to local [staging] [--sites ampas guilds rsvp]
                 [--attendees none|masked|real] [--no-db] [--no-uploads] [--no-backup]
                 [--small] [--plan] [--yes]

For each site, in order:
  1. Backs up each target database to _db/ (timestamped, full), unless --no-backup.
  2. Dumps the source database through an SSH tunnel to the instance (the managed database is
     only reachable from it) with a disposable MySQL 8.0.45 client container, the servers' own
     version. RSVP copies every table's structure; its rows depend on --attendees:
       none (default)  no rows from attendees and cancellations.
       masked          attendee rows with names, emails, guest names and stored messages
                       replaced inside the source query, so real values never reach disk or
                       the target. Each email maps to a-<hash>@example.invalid, the hash keyed
                       per run, so one person keeps one address within a copy.
       real            real attendee rows. The mini only, after warnings and two prompts.
     Outside real, the staff mailboxes (screenings.rsvp_email, cities.rsvp_email,
     movies.reply_to_email) are masked the same way (staff-<hash>@example.invalid). Admin users
     keep their real addresses so they can log in. ci_sessions and login_attempts never copy
     rows.
  3. Replaces each target database with the dump. Every target table is dropped first, so the
     target ends as an exact copy. A local WordPress import also becomes the site's re-seed copy
     (_db/<name>.sql). WordPress targets then drop the titles-catalog transient.
  4. Copies WordPress uploads, additively (nothing is deleted; .gitkeep is left alone): source
     to the mini's checkout, then the mini to staging when staging is a target. --small skips
     files over 5MB; override the cutoff with SYNC_MAX_SIZE (rsync --max-size syntax).

Production is only ever read; it is never a target. Staging writes need --yes. --plan prints
the steps and exits without touching anything.

Credentials come from each site's config on the instance (WordPress .env, RSVP's CodeIgniter
database config) or the local container's environment, into this process only. They reach the
client containers through MYSQL_PWD and are never echoed or written.

Access: staging uses the SSH host STAGING_HOST (default amazon-fyc-stage). Production uses a
temporary Lightsail key fetched with the aws CLI (profile SYNC_AWS_PROFILE, default
amazon-lightsail-staging), kept in a private temp dir and deleted on exit.
"""

from __future__ import annotations

import argparse
import contextlib
import decimal
import json
import os
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Callable, Dict, Iterator, List, Optional, Tuple


def find_workspace() -> Path:
    """Return the amazon/ workspace: the nearest parent holding _db/ and _server/."""
    for parent in Path(__file__).resolve().parents:
        if (parent / "_db").is_dir() and (parent / "_server").is_dir():
            return parent
    raise SystemExit("sync-data: no workspace with _db/ and _server/ above this script")


WORKSPACE = find_workspace()
DB_DIR = WORKSPACE / "_db"
MYSQL_IMAGE = "mysql:8.0.45"
STAGING_HOST = os.environ.get("STAGING_HOST", "amazon-fyc-stage")
PRODUCTION_INSTANCE = "amazon-fyc-production"
AWS_REGION = "us-west-2"
AWS_PROFILE = os.environ.get("SYNC_AWS_PROFILE", "amazon-lightsail-staging")
MAX_SIZE = os.environ.get("SYNC_MAX_SIZE", "5m")

# RSVP rows that never copy: transient state.
RSVP_TRANSIENT = ["ci_sessions", "login_attempts"]
# Personal data, column by column, and how each column is masked.
ATTENDEE_MASKS = {
    "attendees": {"first_name": "guest", "last_name": "row_id", "email": "attendee_email",
                  "guest_names": "blank", "emailMsg": "blank"},
    "cancellations": {"email": "attendee_email", "emailMsg": "blank"},
}
# Staff and publicist mailboxes: email-only RSVP addresses and per-movie reply-to.
STAFF_MASKS = {
    "screenings": {"rsvp_email": "staff_email"},
    "cities": {"rsvp_email": "staff_email"},
    "movies": {"reply_to_email": "staff_email"},
}
INSERT_BATCH = 500
TITLES_CACHE_SQL = (
    "DELETE FROM wp_options WHERE option_name LIKE '%transient%vm_titles_catalog%'"
)
DUMP_FLAGS = [
    "--single-transaction", "--no-tablespaces", "--set-gtid-purged=OFF", "--hex-blob",
    "--default-character-set=utf8mb4",
]


@dataclass(frozen=True)
class Site:
    """One site's database and checkout coordinates."""

    name: str
    container: str
    dump_name: str
    remote_root: str
    wordpress: bool

    @property
    def local_uploads(self) -> Path:
        """The mini's uploads directory for a WordPress site."""
        return WORKSPACE / self.name / "web/app/uploads"


SITES = {
    "ampas": Site(
        "ampas", "ampas-mysql", "amazon-studios-ampas-db",
        "/var/www/html/amazon-studios-ampas", True,
    ),
    "guilds": Site(
        "guilds", "guilds-mysql", "amazon-studios-guilds-db",
        "/var/www/html/amazon-studios-guilds", True,
    ),
    "rsvp": Site("rsvp", "rsvp-mysql", "rsvp", "/var/www/html/rsvp", False),
}


@dataclass(frozen=True)
class Creds:
    """Database connection values. The password never reaches argv or output."""

    host: str
    port: int
    user: str
    password: str
    name: str


@dataclass(frozen=True)
class Remote:
    """An instance reached over SSH: staging or production."""

    env: str
    destination: str
    ssh_options: Tuple[str, ...] = ()

    def ssh(self, *extra: str) -> List[str]:
        """Return the ssh argv for this instance, ending at the destination."""
        return ["ssh", *self.ssh_options, "-o", "ConnectTimeout=15", *extra, self.destination]

    def run(self, command: str) -> str:
        """Run a shell command on the instance and return its stdout."""
        result = subprocess.run(
            [*self.ssh(), command], check=True, capture_output=True, text=True
        )
        return result.stdout

    def rsync_shell(self) -> str:
        """Return the rsync -e value that reaches this instance."""
        return " ".join(shlex.quote(part) for part in ["ssh", *self.ssh_options])


def log(message: str) -> None:
    """Print one progress line."""
    print(message, flush=True)


@contextlib.contextmanager
def production_remote() -> Iterator[Remote]:
    """Yield production with a temporary Lightsail key, deleted on exit."""
    result = subprocess.run(
        [
            "aws", "lightsail", "get-instance-access-details", "--region", AWS_REGION,
            "--instance-name", PRODUCTION_INSTANCE, "--protocol", "ssh", "--output", "json",
        ],
        check=True, capture_output=True, text=True,
        env={**os.environ, "AWS_PROFILE": AWS_PROFILE},
    )
    details = json.loads(result.stdout)["accessDetails"]
    key_dir = Path(tempfile.mkdtemp(prefix="sync-data-"))
    try:
        key = key_dir / "key"
        cert = key_dir / "key-cert.pub"
        key.write_text(details["privateKey"])
        key.chmod(0o600)
        cert.write_text(details["certKey"])
        yield Remote(
            "production",
            f"{details['username']}@{details['ipAddress']}",
            ("-i", str(key), "-o", f"CertificateFile={cert}", "-o", "IdentitiesOnly=yes"),
        )
    finally:
        shutil.rmtree(key_dir, ignore_errors=True)


def parse_env(text: str) -> Dict[str, str]:
    """Parse KEY=VALUE lines from dotenv text without evaluating anything."""
    values = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def remote_creds(remote: Remote, site: Site) -> Creds:
    """Read a site's database values from its config on the instance."""
    if site.wordpress:
        root = site.remote_root
        env = parse_env(remote.run(f"cat {root}/.env {root}/.env.local 2>/dev/null || true"))
        host, _, port = env["DB_HOST"].partition(":")
        return Creds(host, int(port or env.get("DB_PORT") or 3306), env["DB_USER"],
                     env["DB_PASSWORD"], env["DB_NAME"])
    config = f"{site.remote_root}/admin/application/config/{remote.env}/database.php"
    php = (
        f'define("BASEPATH", "x"); define("ENVIRONMENT", "{remote.env}"); $db = [];'
        f' include "{config}"; $d = $db["default"];'
        ' echo json_encode(["host" => $d["hostname"], "port" => $d["port"] ?? 3306,'
        ' "user" => $d["username"], "password" => $d["password"], "name" => $d["database"]]);'
    )
    data = json.loads(remote.run(f"php -r {shlex.quote(php)}"))
    return Creds(data["host"], int(data["port"] or 3306), data["user"], data["password"],
                 data["name"])


def free_port() -> int:
    """Return a free localhost TCP port."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


@contextlib.contextmanager
def tunnel(remote: Remote, creds: Creds) -> Iterator[int]:
    """Forward a free local port to the managed database through the instance."""
    port = free_port()
    process = subprocess.Popen(
        remote.ssh(
            "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ControlMaster=no",
            "-o", "ControlPath=none", "-L", f"127.0.0.1:{port}:{creds.host}:{creds.port}",
        )
    )
    try:
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise RuntimeError(f"the {remote.env} tunnel exited early")
            try:
                socket.create_connection(("127.0.0.1", port), 1).close()
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError(f"the {remote.env} tunnel did not open") from None
                time.sleep(0.5)
        yield port
    finally:
        process.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=10)


def tunnel_client(
    program: List[str], creds: Creds, port: int, tail: Optional[List[str]] = None,
    stdin: Optional[IO[bytes]] = None, stdout: Optional[IO[bytes]] = None,
) -> None:
    """Run mysql or mysqldump in a disposable client container against a tunnel port."""
    subprocess.run(
        [
            "docker", "run", "--rm", "-i", "-e", "MYSQL_PWD", MYSQL_IMAGE, *program,
            "-h", "host.docker.internal", "-P", str(port), "-u", creds.user,
            "--ssl-mode=DISABLED", creds.name, *(tail or []),
        ],
        check=True, stdin=stdin, stdout=stdout, env={**os.environ, "MYSQL_PWD": creds.password},
    )


def local_client(
    site: Site, program: str, stdin: Optional[IO[bytes]] = None,
    stdout: Optional[IO[bytes]] = None,
) -> None:
    """Run mysql or mysqldump inside the site's local container as its root user."""
    subprocess.run(
        [
            "docker", "exec", "-i", site.container, "sh", "-c",
            f'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec {program} -uroot "$MYSQL_DATABASE"',
        ],
        check=True, stdin=stdin, stdout=stdout,
    )


def write_file(path: Path, fill: Callable[[IO[bytes]], None]) -> None:
    """Fill a file through a .partial sibling, renamed into place only on success."""
    partial = path.with_name(path.name + ".partial")
    try:
        with partial.open("wb") as handle:
            fill(handle)
        partial.rename(path)
    finally:
        partial.unlink(missing_ok=True)


def mask_expression(kind: str, column: str, key: str) -> str:
    """Return the SQL that replaces one column's value with its mask, keeping NULLs."""
    col = f"`{column}`"
    hashed = f"LEFT(SHA2(CONCAT('{key}', LOWER(TRIM({col}))), 256), 12)"
    masks = {
        "attendee_email": f"CONCAT('a-', {hashed}, '@example.invalid')",
        "staff_email": f"CONCAT('staff-', {hashed}, '@example.invalid')",
        "guest": "'Guest'",
        "row_id": "CAST(`id` AS CHAR)",
        "blank": "''",
    }
    if kind.endswith("_email"):
        return f"IF(NULLIF(TRIM({col}), '') IS NULL, {col}, {masks[kind]})"
    return f"IF({col} IS NULL, NULL, {masks[kind]})"


def sql_literal(value: object) -> str:
    """Return a MySQL literal for one JSON-decoded value."""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, decimal.Decimal)):
        return str(value)
    if not isinstance(value, str):
        raise RuntimeError(f"cannot copy a {type(value).__name__} value")
    if value.startswith("base64:type"):
        raise RuntimeError("binary columns cannot go through the masked copy")
    escaped = (value.replace("\\", "\\\\").replace("'", "\\'").replace("\0", "\\0")
               .replace("\n", "\\n").replace("\r", "\\r").replace("\x1a", "\\Z"))
    return f"'{escaped}'"


def export_masked(
    creds: Creds, port: int, table: str, masks: Dict[str, str], key: str, handle: IO[bytes],
) -> int:
    """Write a table's rows as INSERTs, masked inside the source query; return the row count."""
    def query(sql: str) -> List[str]:
        with tempfile.TemporaryFile() as taken:
            tunnel_client(["mysql", "-N", "--raw", "--default-character-set=utf8mb4",
                           "-e", sql], creds, port, stdout=taken)
            taken.seek(0)
            return taken.read().decode("utf-8").splitlines()

    columns = query("SELECT column_name FROM information_schema.columns WHERE table_schema ="
                    f" DATABASE() AND table_name = '{table}' ORDER BY ordinal_position")
    unknown = sorted(set(masks) - set(columns))
    if unknown:
        raise RuntimeError(f"{table}: masked columns not found: {unknown}")
    selects = [mask_expression(masks[c], c, key) if c in masks else f"`{c}`" for c in columns]
    rows = query(f"SELECT JSON_ARRAY({', '.join(selects)}) FROM `{table}`")
    names = ", ".join(f"`{c}`" for c in columns)
    for start in range(0, len(rows), INSERT_BATCH):
        values = []
        for line in rows[start:start + INSERT_BATCH]:
            fields = json.loads(line, parse_float=decimal.Decimal)
            values.append("(" + ", ".join(sql_literal(v) for v in fields) + ")")
        rows_sql = ",\n".join(values)
        handle.write(f"INSERT INTO `{table}` ({names}) VALUES\n{rows_sql};\n".encode("utf-8"))
    return len(rows)


def rsvp_masks(attendees: str) -> Dict[str, Dict[str, str]]:
    """Return the tables RSVP rewrites through the masked copy, for an attendees mode."""
    if attendees == "real":
        return {}
    if attendees == "masked":
        return {**STAFF_MASKS, **ATTENDEE_MASKS}
    return dict(STAFF_MASKS)


def rsvp_structure_only(attendees: str) -> List[str]:
    """Return the RSVP tables that copy their structure and no rows."""
    return RSVP_TRANSIENT + ([] if attendees in ("masked", "real") else list(ATTENDEE_MASKS))


def dump_source(remote: Remote, site: Site, out: Path, attendees: str) -> None:
    """Dump a site's source database; RSVP holds back or masks rows per the attendees mode."""
    creds = remote_creds(remote, site)
    with tunnel(remote, creds) as port:
        def fill(handle: IO[bytes]) -> None:
            if site.wordpress:
                tunnel_client(["mysqldump", *DUMP_FLAGS], creds, port, stdout=handle)
                return
            masks = rsvp_masks(attendees)
            apart = rsvp_structure_only(attendees) + list(masks)
            ignore = [f"--ignore-table={creds.name}.{table}" for table in apart]
            tunnel_client(["mysqldump", *DUMP_FLAGS, *ignore], creds, port, stdout=handle)
            tunnel_client(["mysqldump", *DUMP_FLAGS, "--no-data"], creds, port,
                          tail=apart, stdout=handle)
            if not masks:
                return
            key = secrets.token_hex(16)
            # As mysqldump does: without NO_AUTO_VALUE_ON_ZERO an inserted id of 0 takes the next
            # AUTO_INCREMENT value instead (cities.city_id 0 is Los Angeles).
            handle.write(b"SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\n"
                         b"SET @SYNC_OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO';\n")
            for table, columns in masks.items():
                count = export_masked(creds, port, table, columns, key, handle)
                log(f"        {site.name}: {table} {count} rows, masked {', '.join(columns)}")
            handle.write(b"SET SQL_MODE=@SYNC_OLD_SQL_MODE;\nSET FOREIGN_KEY_CHECKS=1;\n")
        write_file(out, fill)


REAL_WARNING = """
  WARNING: --attendees real copies REAL attendee names, email addresses and guest names
  from {source} onto the mini.

  - Anything on the mini that sends RSVP mail from this copy can reach real people.
  - RSVP's mail guard sends non-production mail to dev@cia-adv.com, but it treats an
    unknown environment as production and sends for real.
  - The dump in _db/ holds the personal data. Delete it when you are done.
"""


def confirm_real(source: str) -> None:
    """Warn, then ask twice before real attendee data is copied; exit on anything else."""
    if not sys.stdin.isatty():
        raise SystemExit("sync-data: --attendees real needs an interactive terminal")
    print(REAL_WARNING.format(source=source), file=sys.stderr, flush=True)
    if input("Type 'real attendees' to continue: ").strip() != "real attendees":
        raise SystemExit("sync-data: stopped, nothing ran")
    print("\n  Are you sure? Real people can be emailed from this copy.", file=sys.stderr)
    if input("Type 'yes, mini only' to copy real attendee data: ").strip() != "yes, mini only":
        raise SystemExit("sync-data: stopped, nothing ran")


def backup_target(target: str, staging: Optional[Remote], site: Site, out: Path) -> None:
    """Write a full dump of a target database before it is replaced."""
    if target == "local":
        write_file(out, lambda handle: local_client(
            site, "mysqldump " + " ".join(DUMP_FLAGS), stdout=handle))
        return
    assert staging is not None
    creds = remote_creds(staging, site)
    with tunnel(staging, creds) as port:
        write_file(out, lambda handle: tunnel_client(
            ["mysqldump", *DUMP_FLAGS], creds, port, stdout=handle))


MysqlRunner = Callable[[IO[bytes], Optional[IO[bytes]]], None]


@contextlib.contextmanager
def target_mysql(target: str, staging: Optional[Remote], site: Site) -> Iterator[MysqlRunner]:
    """Yield a runner that feeds SQL to the target database's mysql client."""
    if target == "local":
        yield lambda given, taken: local_client(site, "mysql -N", stdin=given, stdout=taken)
        return
    assert staging is not None
    creds = remote_creds(staging, site)
    with tunnel(staging, creds) as port:
        yield lambda given, taken: tunnel_client(
            ["mysql", "-N"], creds, port, stdin=given, stdout=taken)


def run_sql(mysql: MysqlRunner, sql: str) -> str:
    """Run SQL text through a runner and return its tab-separated output."""
    with tempfile.TemporaryFile() as given, tempfile.TemporaryFile() as taken:
        given.write(sql.encode())
        given.seek(0)
        mysql(given, taken)
        taken.seek(0)
        return taken.read().decode()


def list_tables(mysql: MysqlRunner) -> List[Tuple[str, str]]:
    """Return (name, type) for every table and view in the target database."""
    output = run_sql(mysql, "SELECT table_name, table_type FROM information_schema.tables"
                            " WHERE table_schema = DATABASE();")
    rows = []
    for line in output.splitlines():
        if line:
            name, _, kind = line.partition("\t")
            rows.append((name, kind))
    return rows


def reset_sql(tables: List[Tuple[str, str]]) -> str:
    """Return SQL that drops every listed table and view, foreign keys off."""
    views = [name for name, kind in tables if kind == "VIEW"]
    bases = [name for name, kind in tables if kind != "VIEW"]
    statements = ["SET FOREIGN_KEY_CHECKS=0;"]
    if views:
        statements.append("DROP VIEW IF EXISTS " + ", ".join(f"`{v}`" for v in views) + ";")
    if bases:
        statements.append("DROP TABLE IF EXISTS " + ", ".join(f"`{t}`" for t in bases) + ";")
    statements.append("SET FOREIGN_KEY_CHECKS=1;")
    return "\n".join(statements)


def dumped_tables(dump: Path) -> List[str]:
    """Return the table names a dump creates."""
    names = []
    with dump.open("rb") as handle:
        for line in handle:
            if line.startswith(b"CREATE TABLE `"):
                names.append(line.split(b"`")[1].decode())
    return sorted(set(names))


def import_target(target: str, staging: Optional[Remote], site: Site, dump: Path) -> int:
    """Replace a target database with a dump; return its table count once checked."""
    with target_mysql(target, staging, site) as mysql:
        run_sql(mysql, reset_sql(list_tables(mysql)))
        with dump.open("rb") as handle:
            mysql(handle, None)
        if site.wordpress:
            run_sql(mysql, TITLES_CACHE_SQL + ";")
        present = sorted(name for name, kind in list_tables(mysql) if kind != "VIEW")
    expected = dumped_tables(dump)
    if present != expected:
        missing = sorted(set(expected) - set(present))
        extra = sorted(set(present) - set(expected))
        raise RuntimeError(f"{site.name} {target}: tables differ from the dump"
                           f" (missing {missing}, extra {extra})")
    return len(present)


def rsync(source: str, destination: str, shell: Optional[str], small: bool) -> None:
    """Copy an uploads tree additively, never deleting and never touching .gitkeep."""
    # Folder times are skipped: staging's upload folders belong to www-data, and setting their
    # times fails for the ssh user while the files themselves copy fine.
    argv = ["rsync", "-rltz", "--omit-dir-times", "--info=progress2", "--exclude", ".gitkeep"]
    if small:
        argv.append(f"--max-size={MAX_SIZE}")
    if shell:
        argv += ["-e", shell]
    subprocess.run([*argv, source, destination], check=True)


@dataclass
class Step:
    """One planned action: a description for --plan and the work itself."""

    description: str
    run: Callable[[], None]


def build_steps(
    args: argparse.Namespace, source: Remote, staging: Optional[Remote], stamp: str,
) -> List[Step]:
    """Lay out every action of the run, in order."""
    steps: List[Step] = []
    for name in args.sites:
        site = SITES[name]
        if args.db:
            pii = "-REAL-PII" if args.attendees == "real" and not site.wordpress else ""
            fetched = DB_DIR / f"{site.dump_name}--{source.env}-{stamp}{pii}.sql"
            if args.backup:
                for target in args.to:
                    out = DB_DIR / f"{site.dump_name}_{target}-backup--{stamp}.sql"
                    steps.append(Step(
                        f"backup  {name}: {target} database -> {out.relative_to(WORKSPACE)}",
                        lambda t=target, s=site, o=out: backup_target(t, staging, s, o),
                    ))
            held = "" if site.wordpress else {
                "none": " (no attendee rows; staff mailboxes masked)",
                "masked": " (attendees and staff mailboxes masked)",
                "real": " (REAL attendee data)",
            }[args.attendees]
            steps.append(Step(
                f"dump    {name}: {source.env} database{held} -> {fetched.relative_to(WORKSPACE)}",
                lambda s=site, f=fetched: dump_source(source, s, f, args.attendees),
            ))
            for target in args.to:
                def replace(t: str = target, s: Site = site, f: Path = fetched) -> None:
                    count = import_target(t, staging, s, f)
                    log(f"        {s.name}: {t} now has {count} tables")
                    if t == "local" and s.wordpress:
                        shutil.copyfile(f, DB_DIR / f"{s.dump_name}.sql")
                seed = " and re-seed copy" if target == "local" and site.wordpress else ""
                steps.append(Step(
                    f"import  {name}: replace {target} database{seed} <- {source.env} dump",
                    replace,
                ))
        if args.uploads and site.wordpress:
            local = f"{site.local_uploads}/"
            steps.append(Step(
                f"uploads {name}: {source.env} -> mini checkout (additive)",
                lambda s=site, d=local: rsync(
                    f"{source.destination}:{s.remote_root}/web/app/uploads/", d,
                    source.rsync_shell(), args.small),
            ))
            if "staging" in args.to and staging is not None:
                steps.append(Step(
                    f"uploads {name}: mini checkout -> staging (additive)",
                    lambda s=site, d=local: rsync(
                        d, f"{staging.destination}:{s.remote_root}/web/app/uploads/",
                        staging.rsync_shell(), args.small),
                ))
    return steps


def parse_args(argv: List[str]) -> argparse.Namespace:
    """Parse and check the command line."""
    parser = argparse.ArgumentParser(
        description="Copy site data down from production or staging.",
    )
    parser.add_argument("--from", dest="source", required=True,
                        choices=["production", "staging"])
    parser.add_argument("--to", nargs="+", required=True, choices=["local", "staging"])
    parser.add_argument("--sites", nargs="+", default=list(SITES), choices=list(SITES))
    parser.add_argument("--attendees", choices=["none", "masked", "real"], default="none",
                        help="RSVP attendee rows: none (default), masked, or real (mini only)")
    parser.add_argument("--no-db", dest="db", action="store_false")
    parser.add_argument("--no-uploads", dest="uploads", action="store_false")
    parser.add_argument("--no-backup", dest="backup", action="store_false")
    parser.add_argument("--small", action="store_true", help="skip uploads over SYNC_MAX_SIZE")
    parser.add_argument("--plan", action="store_true", help="print the steps and exit")
    parser.add_argument("--yes", action="store_true", help="confirm writes to staging")
    args = parser.parse_args(argv)
    args.to = list(dict.fromkeys(args.to))
    if args.source in args.to:
        parser.error(f"--from {args.source} cannot also be a target")
    if args.attendees == "real" and args.to != ["local"]:
        parser.error("--attendees real only goes to the mini: use --to local alone")
    if "staging" in args.to and not (args.yes or args.plan):
        parser.error("writing to staging needs --yes (run --plan first)")
    return args


def main(argv: List[str]) -> int:
    """Run the sync."""
    args = parse_args(argv)
    if args.attendees == "real" and "rsvp" in args.sites and args.db and not args.plan:
        confirm_real(args.source)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    with contextlib.ExitStack() as stack:
        staging = Remote("staging", STAGING_HOST)
        if args.source == "staging":
            source = staging
        elif args.plan:
            source = Remote("production", "production (temporary key)")
        else:
            source = stack.enter_context(production_remote())
        targets_staging = staging if "staging" in args.to else None
        steps = build_steps(args, source, targets_staging, stamp)
        log(f"sync-data: {args.source} -> {', '.join(args.to)}; {len(steps)} steps")
        for number, step in enumerate(steps, 1):
            log(f"[{number}/{len(steps)}] {step.description}")
            if not args.plan:
                step.run()
    log("planned only; nothing ran" if args.plan else "done")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except subprocess.CalledProcessError as error:
        print(f"failed: {' '.join(map(str, error.cmd[:6]))} ... exit {error.returncode}",
              file=sys.stderr)
        sys.exit(1)
    except RuntimeError as error:
        print(f"failed: {error}", file=sys.stderr)
        sys.exit(1)
