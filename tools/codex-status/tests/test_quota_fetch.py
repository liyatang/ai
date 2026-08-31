import contextlib
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import quota_fetch  # noqa: E402


class QuotaFetchTests(unittest.TestCase):
    def test_parse_window_normalizes_fractional_percent(self):
        window = quota_fetch.parse_gpt_window({
            "limit_window_seconds": 604800,
            "used_percent": 12.6,
            "reset_at": 123,
        })
        self.assertEqual(window["id"], "周")
        self.assertEqual(window["used_pct"], 13)
        self.assertEqual(
            quota_fetch.parse_gpt_window({"used_percent": 120})["used_pct"], 100
        )

    def test_missing_codex_login_has_compact_degradation_reason(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = os.path.join(directory, "auth.json")
            with self.assertRaisesRegex(quota_fetch.FetchError, "未检测到 Codex"):
                quota_fetch.fetch_gpt_codex(
                    {"auth_json": missing}, timeout=1, proxy=None
                )

    def test_config_failure_is_exposed_as_gpt_error(self):
        old_path = quota_fetch.CONFIG_PATH
        try:
            with tempfile.TemporaryDirectory() as directory:
                quota_fetch.CONFIG_PATH = os.path.join(directory, "missing.json")
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    quota_fetch.main()
            result = json.loads(output.getvalue())
            self.assertFalse(result["gpt"]["ok"])
            self.assertIn("配置读取失败", result["gpt"]["error"])
        finally:
            quota_fetch.CONFIG_PATH = old_path

    def test_cross_origin_redirect_does_not_forward_authorization(self):
        received = []

        class DestinationHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                received.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")

            def log_message(self, *_args):
                pass

        destination = ThreadingHTTPServer(("127.0.0.1", 0), DestinationHandler)

        class RedirectHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header(
                    "Location", f"http://127.0.0.1:{destination.server_port}/target"
                )
                self.end_headers()

            def log_message(self, *_args):
                pass

        source = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        threads = [
            threading.Thread(target=server.serve_forever, daemon=True)
            for server in (source, destination)
        ]
        for thread in threads:
            thread.start()
        try:
            with self.assertRaises(quota_fetch.FetchError):
                quota_fetch.http_json(
                    f"http://127.0.0.1:{source.server_port}/start",
                    headers={"Authorization": "Bearer secret"},
                )
            self.assertEqual(received, [])
        finally:
            source.shutdown()
            destination.shutdown()
            source.server_close()
            destination.server_close()

    def test_cache_is_written_with_private_permissions(self):
        old_path = quota_fetch.CACHE_PATH
        try:
            with tempfile.TemporaryDirectory() as directory:
                quota_fetch.CACHE_PATH = os.path.join(directory, "cache.json")
                quota_fetch.save_cache({"gpt": {"ok": True}})
                self.assertEqual(os.stat(quota_fetch.CACHE_PATH).st_mode & 0o777, 0o600)
                with open(quota_fetch.CACHE_PATH) as file:
                    self.assertTrue(json.load(file)["gpt"]["ok"])
        finally:
            quota_fetch.CACHE_PATH = old_path


if __name__ == "__main__":
    unittest.main()
