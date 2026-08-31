import os
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from diagnostics import TARGET_CLIENT, TARGET_OUTPUT, TARGET_RETRY, TARGET_WEBSOCKET, _decode_chunked, analyze_codex_rows, choose_gpt_recommendation, evaluate_tun, read_codex_activity, read_proxy_state, read_tun_state, record_switch_audit, resolve_gpt_proxy_context, resolve_proxy_state, summarize_node_quality, switch_gpt_node, update_quality_history  # noqa: E402

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

    def test_current_client_target_is_recognized(self):
        now = 1_800_000_000.0
        result = analyze_codex_rows([
            (int(now - 10), 0, TARGET_CLIENT, "TRACE", TURN_A, "gpt-5.6-sol", "medium"),
            (int(now - 7), 0, TARGET_OUTPUT, "DEBUG", TURN_A, None, None),
        ], now)
        self.assertTrue(result["active"])
        self.assertEqual(result["first_output_median_seconds"], 3.0)

    def test_recent_output_keeps_long_turn_active(self):
        now = 1_800_000_000.0
        result = analyze_codex_rows([
            (int(now - 600), 0, TARGET_CLIENT, "TRACE", TURN_A, "gpt-5.6-sol", "medium"),
            (int(now - 10), 0, TARGET_OUTPUT, "DEBUG", TURN_A, None, None),
        ], now)
        self.assertTrue(result["active"])
        self.assertEqual(result["turn_count"], 1)
        self.assertEqual(result["sample_count"], 0)

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
                    (now - 10, 0, "TRACE", TARGET_CLIENT, start),
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
            missing_app = (os.path.join(directory, "Clash Verge.app"),)
            tun = read_tun_state(missing_socket, missing_app)
            self.assertEqual(tun["state"], "unavailable")
            self.assertEqual(tun["detail"], "未安装 Clash Verge")
            proxy = read_proxy_state(missing_socket, missing_app)
            self.assertEqual(proxy["detail"], "未安装 Clash Verge")

            os.mkdir(missing_app[0])
            self.assertEqual(
                read_tun_state(missing_socket, missing_app)["detail"],
                "Clash Verge 未连接",
            )

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
        self.assertEqual(result["selected_name"], "🇯🇵 日本 AI")
        self.assertEqual(result["source"], "policy")

    def test_proxy_keeps_selected_and_active_nodes_separate(self):
        proxies = {
            "🤖 AI": {"now": "🔰 手动选择"},
            "🔰 手动选择": {"now": "🇯🇵 日本 01"},
            "🇯🇵 日本 01": {"type": "Vless"},
        }
        result = resolve_proxy_state(
            {"proxies": proxies},
            {"connections": [{
                "metadata": {"host": "chatgpt.com"},
                "chains": ["🇺🇸 美国 AI", "🔰 手动选择", "🤖 AI"],
            }]},
        )
        self.assertEqual(result["name"], "🇯🇵 日本 01")
        self.assertEqual(result["selected_name"], "🇯🇵 日本 01")
        self.assertEqual(result["active_name"], "🇺🇸 美国 AI")
        self.assertTrue(result["transitioning"])

    def test_gpt_context_uses_deep_selector_and_excludes_hong_kong(self):
        proxies = {
            "🤖 AI": {"type": "Selector", "now": "🔰 手动选择", "all": ["🔰 手动选择"]},
            "🔰 手动选择": {
                "type": "Selector",
                "now": "🇺🇸 美国 AI",
                "all": ["♻️ 自动选择", "🎯 Direct", "🇭🇰 香港 01", "🇸🇬 新加坡 01", "🇺🇸 美国 AI"],
            },
            "♻️ 自动选择": {"type": "URLTest", "now": "🇸🇬 新加坡 01", "all": ["🇸🇬 新加坡 01"]},
            "🎯 Direct": {"type": "Direct"},
            "🇭🇰 香港 01": {"type": "Vless"},
            "🇸🇬 新加坡 01": {"type": "Vless"},
            "🇺🇸 美国 AI": {"type": "Vless"},
        }
        result = resolve_gpt_proxy_context({"proxies": proxies})
        self.assertTrue(result["available"])
        self.assertEqual(result["selector"], "🔰 手动选择")
        self.assertEqual(result["current_name"], "🇺🇸 美国 AI")
        self.assertEqual(result["candidates"], ["🇸🇬 新加坡 01", "🇺🇸 美国 AI"])

    def test_gpt_recommendation_requires_meaningful_gain(self):
        results = [
            {"name": "🇸🇬 新加坡 01", "median_ms": 130, "p90_ms": 150, "max_ms": 150, "success_count": 5, "sample_count": 5},
            {"name": "🇯🇵 日本 01", "median_ms": 170, "p90_ms": 180, "max_ms": 180, "success_count": 5, "sample_count": 5},
            {"name": "🇺🇸 美国 AI", "median_ms": 1200, "p90_ms": 3000, "max_ms": 3000, "success_count": 5, "sample_count": 5},
        ]
        qualities = {
            "🇺🇸 美国 AI": {"status": "unstable", "turn_count": 10},
            "🇯🇵 日本 01": {"status": "stable", "turn_count": 20, "first_attempt_success_pct": 100},
            "🇸🇬 新加坡 01": {"status": "observing", "turn_count": 2},
        }
        picked = choose_gpt_recommendation("🇺🇸 美国 AI", results, qualities)
        self.assertEqual(picked["recommended"]["name"], "🇯🇵 日本 01")
        self.assertEqual(picked["recommendation_kind"], "stable")

        stable_current = {**qualities, "🇺🇸 美国 AI": {"status": "stable", "turn_count": 20}}
        quiet = choose_gpt_recommendation("🇺🇸 美国 AI", results, stable_current)
        self.assertIsNone(quiet["recommended"])
        self.assertIsNone(quiet["trial"])

    def test_unstable_current_only_offers_unverified_candidate_as_trial(self):
        results = [
            {"name": "current", "median_ms": 300, "p90_ms": 400, "max_ms": 400, "success_count": 5, "sample_count": 5},
            {"name": "candidate", "median_ms": 100, "p90_ms": 120, "max_ms": 120, "success_count": 5, "sample_count": 5},
        ]
        picked = choose_gpt_recommendation(
            "current", results,
            {"current": {"status": "unstable", "turn_count": 5},
             "candidate": {"status": "observing", "turn_count": 0}},
        )
        self.assertIsNone(picked["recommended"])
        self.assertEqual(picked["trial"]["name"], "candidate")
        self.assertEqual(picked["recommendation_kind"], "trial")

    def test_partial_probe_cannot_be_recommended(self):
        results = [
            {"name": "current", "median_ms": 500, "p90_ms": 600, "success_count": 5, "sample_count": 5},
            {"name": "flaky", "median_ms": 50, "p90_ms": 70, "success_count": 4, "sample_count": 5},
        ]
        picked = choose_gpt_recommendation(
            "current", results,
            {"current": {"status": "unstable"},
             "flaky": {"status": "stable", "first_attempt_success_pct": 100}},
        )
        self.assertIsNone(picked["recommended"])
        self.assertIsNone(picked["trial"])

    def test_quality_history_stable_and_unstable_states(self):
        now = 1_800_000_000.0
        stable_history = {"version": 1, "created_at": now - 1000, "turns": {}, "switches": []}
        stable_turns = [
            {"turn_id": f"stable-{index}", "start_at": now - index, "last_seen_at": now - index,
             "has_output": True, "retry_count": 0}
            for index in range(10)
        ]
        update_quality_history(stable_history, "日本", stable_turns, now)
        stable = summarize_node_quality(stable_history, "日本", now)
        self.assertEqual(stable["status"], "stable")
        self.assertEqual(stable["first_attempt_success_pct"], 100)

        unstable_history = {"version": 1, "created_at": now - 1000, "turns": {}, "switches": []}
        unstable_turns = [
            {"turn_id": "bad", "start_at": now - 10, "last_seen_at": now - 5,
             "has_output": True, "retry_count": 3, "opening_retry_count": 3,
             "tls_eof_count": 2}
        ]
        update_quality_history(unstable_history, "新加坡", unstable_turns, now)
        unstable = summarize_node_quality(unstable_history, "新加坡", now)
        self.assertEqual(unstable["status"], "unstable")
        self.assertEqual(unstable["max_retries_per_turn"], 3)

    def test_turn_overlapping_switch_grace_is_ignored(self):
        now = 1_800_000_000.0
        history = {
            "version": 1,
            "created_at": now - 1000,
            "turns": {},
            "switches": [{"at": now - 10, "from": "新加坡", "to": "日本"}],
        }
        turns = [{
            "turn_id": "during-switch", "start_at": now - 20, "last_seen_at": now - 5,
            "has_output": True, "retry_count": 3,
        }]
        update_quality_history(history, "日本", turns, now)
        self.assertTrue(history["turns"]["during-switch"]["ignored_after_switch"])
        self.assertEqual(summarize_node_quality(history, "新加坡", now)["turn_count"], 0)

    def test_switch_audit_is_private_and_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "switch_audit.jsonl")
            for index in range(5):
                record_switch_audit({"at": index, "ok": True}, path=path, limit=3)
            with open(path, encoding="utf-8") as file:
                entries = [line for line in file.read().splitlines() if line]
            self.assertEqual(len(entries), 3)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    @mock.patch("diagnostics._unix_http_request")
    @mock.patch("diagnostics._unix_http_json")
    def test_switch_gpt_node_targets_resolved_selector(self, read_json, request):
        before = {"proxies": {
            "🤖 AI": {"type": "Selector", "now": "🔰 手动选择", "all": ["🔰 手动选择"]},
            "🔰 手动选择": {
                "type": "Selector",
                "now": "🇺🇸 美国 AI",
                "all": ["🇭🇰 香港 01", "🇸🇬 新加坡 01", "🇺🇸 美国 AI"],
            },
            "🇭🇰 香港 01": {"type": "Vless"},
            "🇸🇬 新加坡 01": {"type": "Vless"},
            "🇺🇸 美国 AI": {"type": "Vless"},
        }}
        after = {"proxies": {
            **before["proxies"],
            "🔰 手动选择": {
                **before["proxies"]["🔰 手动选择"],
                "now": "🇸🇬 新加坡 01",
            },
        }}
        read_json.side_effect = [before, after]
        request.return_value = (204, b"")

        result = switch_gpt_node(
            "🇸🇬 新加坡 01", "/tmp/test.sock", quality_path=None, audit_path=None
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["actual_name"], "🇸🇬 新加坡 01")
        request.assert_called_once_with(
            "/tmp/test.sock",
            "/proxies/%F0%9F%94%B0%20%E6%89%8B%E5%8A%A8%E9%80%89%E6%8B%A9",
            timeout=1.0,
            method="PUT",
            payload={"name": "🇸🇬 新加坡 01"},
        )

    @mock.patch("diagnostics._unix_http_request", return_value=(204, b""))
    @mock.patch("diagnostics._unix_http_json")
    def test_switch_gpt_node_rejects_unconfirmed_selector(self, read_json, _request):
        payload = {"proxies": {
            "🤖 AI": {"type": "Selector", "now": "🔰 手动选择", "all": ["🔰 手动选择"]},
            "🔰 手动选择": {
                "type": "Selector",
                "now": "🇺🇸 美国 AI",
                "all": ["🇸🇬 新加坡 01", "🇺🇸 美国 AI"],
            },
            "🇸🇬 新加坡 01": {"type": "Vless"},
            "🇺🇸 美国 AI": {"type": "Vless"},
        }}
        read_json.side_effect = [payload, payload]

        result = switch_gpt_node(
            "🇸🇬 新加坡 01", "/tmp/test.sock", quality_path=None, audit_path=None
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["actual_name"], "🇺🇸 美国 AI")
        self.assertIn("实际仍为", result["error"])

    def test_decodes_chunked_mihomo_response(self):
        self.assertEqual(_decode_chunked(b"4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"), b"Wikipedia")


if __name__ == "__main__":
    unittest.main()
