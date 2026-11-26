"""Send to production against a stub of WordPress's media endpoint."""

from __future__ import annotations

import base64
import json
import os
import socket
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from encode_review import send
from encode_review.spool import RETENTION_SECONDS, Spool, read_json, write_json


class StubMedia(BaseHTTPRequestHandler):
    """WordPress's media endpoint: POST creates, GET ?search= finds by text."""

    received: list[dict] = []
    created: list[dict] = []
    status = 201
    drop_answer = False  # accept the upload, then close without answering

    def do_POST(self) -> None:  # noqa: N802 - http.server naming
        body = self.rfile.read(int(self.headers["Content-Length"]))
        StubMedia.received.append({"path": self.path, "headers": dict(self.headers), "body": body})
        if StubMedia.status == 201:
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            item = {"id": 321 + len(StubMedia.created),
                    "source_url": "https://prod.example/wp-content/uploads/x.mp4",
                    "description": {"rendered": "<p>" + query["description"][0] + "</p>"}}
            StubMedia.created.append(item)
            if StubMedia.drop_answer:
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            self.answer(201, item)
        else:
            self.answer(StubMedia.status, {"code": "rest_cannot_create",
                                           "message": "Sorry, you are not allowed."})

    def do_GET(self) -> None:  # noqa: N802 - http.server naming
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        term = query.get("search", [""])[0]
        self.answer(200, [item for item in StubMedia.created if term in json.dumps(item)])

    def answer(self, code: int, payload: object) -> None:
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args) -> None:
        pass


class SendTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.spool = Spool(root / "spool")
        self.spool.ensure()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), StubMedia)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        StubMedia.received = []
        StubMedia.created = []
        StubMedia.status = 201
        StubMedia.drop_answer = False
        self.creds_dir = root / "creds"
        self.creds_dir.mkdir()
        url = f"http://127.0.0.1:{self.server.server_port}"
        (self.creds_dir / send.CREDENTIAL_NAME).write_text(
            "# test login\n"
            f"AMPAS_URL={url}/\n"
            "AMPAS_USER=uploader\n"
            "AMPAS_APP_PASSWORD='test test test'\n"
        )
        self.env = mock.patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": str(self.creds_dir)})
        self.env.start()

    def tearDown(self) -> None:
        self.env.stop()
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def queue_send(self, attachment_id: int = 7, site: str = "ampas") -> Path:
        """What the plugin writes under state.lock: the record and the file copy."""
        folder = send.sends_dir(self.spool) / f"{site}-{attachment_id}"
        folder.mkdir()
        (folder / send.PAYLOAD).write_bytes(b"\x00video-bytes")
        write_json(folder / send.RECORD, {
            "site": site, "staging_attachment_id": attachment_id,
            "filename": "Trailer Final (v2).mp4", "mime": "video/mp4", "title": "Trailer Final",
            "state": "queued",
            "tries": [{"n": 1, "token": send.new_token(site, attachment_id, 1),
                       "requested_by": "editor", "requested_at": 100}],
        })
        return folder

    def test_configured_sites(self) -> None:
        self.assertEqual(send.configured_sites(), {"ampas": True, "guilds": False})

    def test_send_uploads_one_file_and_records_the_result(self) -> None:
        folder = self.queue_send()
        self.assertEqual(send.pending_sends(self.spool), [folder])
        record = send.process_send(self.spool, folder)
        self.assertEqual(record["state"], "sent")
        self.assertEqual(record["production_id"], 321)
        upload = StubMedia.received[0]
        token = record["tries"][0]["token"]
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(upload["path"]).query),
                         {"title": ["Trailer Final"], "description": [send.description(token)]})
        self.assertEqual(upload["body"], b"\x00video-bytes")
        self.assertEqual(upload["headers"]["Content-Type"], "video/mp4")
        self.assertEqual(upload["headers"]["Content-Disposition"],
                         'attachment; filename="Trailer-Final-v2-.mp4"')
        login = base64.b64encode(b"uploader:test test test").decode()
        self.assertEqual(upload["headers"]["Authorization"], f"Basic {login}")
        self.assertEqual(read_json(folder / send.RECORD)["state"], "sent")
        self.assertFalse((folder / send.PAYLOAD).exists())
        self.assertEqual(send.pending_sends(self.spool), [])
        # A second pass, or a second worker, finds nothing to send.
        self.assertEqual(send.process_send(self.spool, folder)["state"], "sent")
        self.assertEqual(len(StubMedia.received), 1)

    def test_refusal_is_a_known_failure(self) -> None:
        StubMedia.status = 403
        folder = self.queue_send()
        record = send.process_send(self.spool, folder)
        self.assertEqual(record["state"], "failed")
        self.assertIn("403", record["tries"][0]["error"])
        self.assertIn("not allowed", record["tries"][0]["error"])
        self.assertEqual(send.due_checks(self.spool, at=10**10), [])

    def test_server_error_leaves_the_outcome_unknown(self) -> None:
        StubMedia.status = 504
        record = send.process_send(self.spool, self.queue_send())
        self.assertEqual(record["state"], "unknown")
        self.assertIn("504", record["tries"][0]["error"])

    def test_unreachable_production_is_a_known_failure(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        record = send.process_send(self.spool, self.queue_send())
        self.assertEqual(record["state"], "failed")
        self.assertIn("Could not reach production", record["tries"][0]["error"])

    def test_cut_off_answer_is_settled_by_lookup_not_by_sending_again(self) -> None:
        StubMedia.drop_answer = True
        folder = self.queue_send()
        record = send.process_send(self.spool, folder)
        self.assertEqual(record["state"], "unknown")
        self.assertTrue((folder / send.PAYLOAD).exists())
        self.assertEqual(send.pending_sends(self.spool), [])
        started = record["tries"][0]["started_at"]
        self.assertEqual(send.due_checks(self.spool, at=started + send.SETTLE_S - 1), [])
        self.assertEqual(send.due_checks(self.spool, at=started + send.SETTLE_S), [folder])
        record = send.check_send(self.spool, folder)
        self.assertEqual(record["state"], "sent")
        self.assertEqual(record["production_id"], 321)
        self.assertEqual(record["tries"][0]["outcome"], "found")
        self.assertEqual(len(StubMedia.received), 1)
        self.assertFalse((folder / send.PAYLOAD).exists())

    def test_worker_stop_during_upload_never_resends(self) -> None:
        folder = self.queue_send()
        record = read_json(folder / send.RECORD)
        record["state"] = "sending"
        record["tries"][0]["started_at"] = 1000
        write_json(folder / send.RECORD, record)
        self.assertEqual(send.recover_interrupted(self.spool), [folder.name])
        record = read_json(folder / send.RECORD)
        self.assertEqual(record["state"], "unknown")
        self.assertEqual(record["check_after"], 1000 + send.SETTLE_S)
        self.assertEqual(send.pending_sends(self.spool), [])
        # Production never got it: the lookup finds nothing and allows a new send.
        record = send.check_send(self.spool, folder)
        self.assertEqual(record["state"], "failed")
        self.assertIn("can be sent again", record["tries"][0]["error"])
        self.assertEqual(StubMedia.received, [])

    def test_failed_lookup_keeps_the_send_unknown(self) -> None:
        folder = self.queue_send()
        record = read_json(folder / send.RECORD)
        record.update(state="unknown", check_after=0)
        write_json(folder / send.RECORD, record)
        self.server.shutdown()
        self.server.server_close()
        record = send.check_send(self.spool, folder)
        self.assertEqual(record["state"], "unknown")
        self.assertIn("Could not reach production", record["check_error"])
        self.assertGreater(record["check_after"], 0)

    def test_operator_resolves_an_unknown_send(self) -> None:
        folder = self.queue_send()
        record = read_json(folder / send.RECORD)
        record.update(state="unknown", check_after=0)
        write_json(folder / send.RECORD, record)
        record = send.resolve(self.spool, folder.name, 4151)
        self.assertEqual((record["state"], record["production_id"]), ("sent", 4151))
        with self.assertRaises(ValueError):
            send.resolve(self.spool, folder.name, None)

    def test_record_outlives_cleanup(self) -> None:
        StubMedia.drop_answer = True
        folder = self.queue_send()
        send.process_send(self.spool, folder)
        later = int(time.time()) + RETENTION_SECONDS + 60
        self.assertIn(f"sends/{folder.name}/file.mp4", self.spool.cleanup(at=later))
        record = read_json(folder / send.RECORD)
        self.assertEqual(record["state"], "unknown")
        # The lookup still settles it after the file copy is gone.
        self.assertEqual(send.check_send(self.spool, folder)["state"], "sent")
        self.assertEqual(self.spool.cleanup(at=later + RETENTION_SECONDS), [])
        self.assertEqual(read_json(folder / send.RECORD)["production_id"], 321)

    def test_site_without_login_is_refused_without_a_request(self) -> None:
        record = send.process_send(self.spool, self.queue_send(site="guilds"))
        self.assertEqual(record["state"], "failed")
        self.assertIn("not set up", record["tries"][0]["error"])
        self.assertEqual(StubMedia.received, [])

    def test_no_credential_store_means_nothing_configured(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(send.configured_sites(), {"ampas": False, "guilds": False})


if __name__ == "__main__":
    unittest.main()
