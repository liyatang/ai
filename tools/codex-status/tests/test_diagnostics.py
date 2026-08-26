import os
import sqlite3
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from diagnostics import TARGET_OUTPUT, TARGET_RETRY, TARGET_WEBSOCKET, _decode_chunked, analyze_codex_rows, evaluate_tun, read_codex_activity, read_tun_state, resolve_proxy_state  # noqa: E402

TURN_A = "01a00000-0000-7000-8000-000000000001"
TURN_B = "01a00000-0000-7000-8000-000000000002"


class DiagnosticsTests(unittest.TestCase):
    def test_aggregates_concurrent_turns_without_content(self):
        now = 1_800_000_000.0
        rows = [
            (int(now - 20), 0, TARGET_WEBSOCKET, "INFO", TURN_A, "gpt-5.6-sol", "medium"),
            (int(now - 18), 0, TARGET_WEBSOCKET, "INFO", TURN_B, "gpt-5.6-luna", "low"),
            (int(now - 14), 0, TARGET_OUTPUT, "DEBUG", TURN_A, None, None),
            (int(now - 10), 0, TARGET_OUTPUT, "DEBUG", TURN_B, None, None),
            (int(now - 9), 0, TARGET_RETRY, "WARN", TURN_B, None, None),
        ]
        result = analyze_codex_rows(rows, now)
        self.assertTrue(result["active"])
        self.assertEqual(result["turn_count"], 2)
        self.assertEqual(result["sample_count"], 2)
        self.assertEqual(result["first_output_median_seconds"], 7.0)
        self.assertEqual(result["retry_count"], 1)
        self.assertEqual(result["model"], "gpt-5.6-luna")
        self.assertEqual(result["reasoning_effort"], "low")

    def test_idle_does_not_reuse_old_turn(self):
        now = 1_800_000_000.0
        result = analyze_codex_rows(
            [(int(now - 301), 0, TARGET_WEBSOCKET, "INFO", TURN_A, "gpt-5.6-sol", "medium")], now
        )
        self.assertFalse(result["active"])
        self.assertIsNone(result["first_output_median_seconds"])

    def test_schema_error_degrades(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "logs.sqlite")
            sqlite3.connect(path).close()
            result = read_codex_activity(path, 1_800_000_000.0)
            self.assertFalse(result["available"])
            self.assertIn("不可用", result["error"])

    def test_sql_extracts_only_performance_metadata(self):
        now = 1_800_000_000
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "logs.sqlite")
            connection = sqlite3.connect(path)
            connection.executescript(
                """
                CREATE TABLE logs (
                  id INTEGER PRIMARY KEY,
                  ts INTEGER NOT NULL,
                  ts_nanos INTEGER NOT NULL,
                  level TEXT NOT NULL,
                  target TEXT NOT NULL,
                  feedback_log_body TEXT
                );
                CREATE INDEX idx_logs_ts ON logs(ts DESC, ts_nanos DESC, id DESC);
                """
            )
            start = (
                f"turn{{codex.turn.reasoning_effort=medium}}:"
                f"run_sampling_request{{turn_id={TURN_A} model=gpt-5.6-sol cwd=/private/secret}}"
            )
            output = (
                f"run_sampling_request{{turn_id={TURN_A}}}: "
                "Output item item_type=\"reasoning\""
            )
            connection.executemany(
                "INSERT INTO logs(ts, ts_nanos, level, target, feedback_log_body) VALUES(?,?,?,?,?)",
                [
                    (now - 10, 0, "INFO", TARGET_WEBSOCKET, start),
                    (now - 7, 0, "DEBUG", TARGET_OUTPUT, output),
                ],
            )
            connection.commit()
            connection.close()

            result = read_codex_activity(path, float(now))
            self.assertTrue(result["active"])
            self.assertEqual(result["model"], "gpt-5.6-sol")
            self.assertEqual(result["reasoning_effort"], "medium")
            self.assertEqual(result["first_output_median_seconds"], 3.0)
            self.assertNotIn("secret", str(result))

    def test_tun_states(self):
        self.assertEqual(evaluate_tun({"tun": {"enable": False}}, "", "")["state"], "disabled")
        enabled = evaluate_tun(
            {"tun": {"enable": True, "device": "utun4"}},
            "  interface: utun4\n",
            "utun4: flags=8051<UP,POINTOPOINT>\n\tinet 198.18.0.1 --> 198.18.0.1\n",
        )
        self.assertEqual(enabled["state"], "enabled")
        mismatch = evaluate_tun(
            {"tun": {"enable": True, "device": "utun4"}},
            "  interface: en0\n",
            "utun4: flags=8051<UP,POINTOPOINT>\n\tinet 198.18.0.1 --> 198.18.0.1\n",
        )
        self.assertEqual(mismatch["state"], "unavailable")

        with tempfile.TemporaryDirectory() as directory:
            missing_socket = os.path.join(directory, "missing.sock")
            self.assertEqual(read_tun_state(missing_socket)["state"], "unavailable")

    def test_proxy_prefers_live_chatgpt_leaf(self):
        result = resolve_proxy_state(
            {"proxies": {}},
            {"connections": [{
                "metadata": {"host": "ws.chatgpt.com"},
                "chains": ["🇯🇵 日本 AI ", "🔰 手动选择", "🤖 AI"],
            }]},
        )
        self.assertEqual(result["name"], "🇯🇵 日本 AI")
        self.assertEqual(result["source"], "connection")

    def test_proxy_recursively_resolves_ai_policy(self):
        proxies = {
            "🤖 AI": {"now": "🔰 手动选择"},
            "🔰 手动选择": {"now": "🇯🇵 日本 AI"},
            "🇯🇵 日本 AI": {"type": "Vless"},
        }
        result = resolve_proxy_state({"proxies": proxies}, {"connections": []})
        self.assertEqual(result["name"], "🇯🇵 日本 AI")
        self.assertEqual(result["source"], "policy")

    def test_decodes_chunked_mihomo_response(self):
        self.assertEqual(_decode_chunked(b"4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"), b"Wikipedia")


if __name__ == "__main__":
    unittest.main()
