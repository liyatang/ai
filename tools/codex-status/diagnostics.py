#!/usr/bin/env python3
"""Codex 状态本地诊断数据层。

只读取 Codex 性能元数据（时间、模型、reasoning、事件类型、重试）与
Clash/mihomo 本机状态；不输出或缓存提示词、工具参数、工作路径。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import socket
import sqlite3
import statistics
import subprocess
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any


LOG_PATH = os.path.expanduser("~/.codex/logs_2.sqlite")
MIHOMO_SOCKET = "/tmp/verge/verge-mihomo.sock"
CLASH_APP_PATHS = (
    "/Applications/Clash Verge.app",
    "/Applications/Clash Verge Rev.app",
    os.path.expanduser("~/Applications/Clash Verge.app"),
    os.path.expanduser("~/Applications/Clash Verge Rev.app"),
)
ACTIVITY_SECONDS = 300
MAX_ROWS = 20_000
GPT_PROBE_URL = "https://chatgpt.com/cdn-cgi/trace"
GPT_PROBE_ROUNDS = 3
GPT_PROBE_TIMEOUT_MS = 6_000
GROUP_PROXY_TYPES = frozenset(("Selector", "URLTest", "Fallback", "LoadBalance"))

TARGET_WEBSOCKET = "codex_api::endpoint::responses_websocket"
TARGET_CLIENT = "codex_core::client"
TARGET_STARTS = frozenset((TARGET_WEBSOCKET, TARGET_CLIENT))
TARGET_OUTPUT = "codex_core::stream_events_utils"
TARGET_RETRY = "codex_core::responses_retry"

@dataclass
class TurnStart:
    at: float
    model: str | None
    reasoning_effort: str | None


def _timestamp(seconds: int, nanos: int) -> float:
    return float(seconds) + float(nanos) / 1_000_000_000


def _percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * fraction)))
    return ordered[index]


def analyze_codex_rows(
    rows: list[tuple[int, int, str, str, str, str | None, str | None]], now: float
) -> dict[str, Any]:
    """把已经过滤为性能元数据的日志行聚合为最近五分钟活动。"""
    cutoff = now - ACTIVITY_SECONDS
    starts: dict[str, TurnStart] = {}
    first_outputs: dict[str, float] = {}
    last_outputs: dict[str, float] = {}
    retries: dict[str, int] = {}

    for seconds, nanos, target, level, turn_id, model, effort in rows:
        if not re.fullmatch(r"[0-9a-f-]{36}", turn_id or ""):
            continue
        at = _timestamp(seconds, nanos)

        if target in TARGET_STARTS:
            previous = starts.get(turn_id)
            if previous is None or at < previous.at:
                starts[turn_id] = TurnStart(at=at, model=model, reasoning_effort=effort)
        elif target == TARGET_OUTPUT and level == "DEBUG":
            first_outputs[turn_id] = min(first_outputs.get(turn_id, at), at)
            last_outputs[turn_id] = max(last_outputs.get(turn_id, at), at)
        elif target == TARGET_RETRY:
            retries[turn_id] = retries.get(turn_id, 0) + 1

    active_ids = {
        turn_id for turn_id, start in starts.items() if start.at >= cutoff
    } | {
        turn_id for turn_id, output_at in last_outputs.items() if output_at >= cutoff
    }
    waits: list[float] = []
    for turn_id in active_ids:
        start = starts.get(turn_id)
        if start is None:
            continue
        output_at = first_outputs.get(turn_id)
        if output_at is None:
            continue
        wait = output_at - start.at
        if 0 <= wait <= ACTIVITY_SECONDS:
            waits.append(wait)

    active_starts = [starts[turn_id] for turn_id in active_ids if turn_id in starts]
    latest = max(active_starts, key=lambda item: item.at) if active_starts else None
    retry_count = sum(retries.get(turn_id, 0) for turn_id in active_ids)
    return {
        "available": True,
        "active": bool(active_ids),
        "window_seconds": ACTIVITY_SECONDS,
        "turn_count": len(active_ids),
        "sample_count": len(waits),
        "first_output_median_seconds": round(statistics.median(waits), 3) if waits else None,
        "first_output_p90_seconds": round(_percentile(waits, 0.9), 3) if waits else None,
        "retry_count": retry_count,
        "model": latest.model if latest else None,
        "reasoning_effort": latest.reasoning_effort if latest else None,
    }


def read_codex_activity(path: str = LOG_PATH, now: float | None = None) -> dict[str, Any]:
    now = time.time() if now is None else now
    if not os.path.exists(path):
        return {"available": False, "active": False, "error": "未找到 Codex 日志"}

    cutoff = int(now) - ACTIVITY_SECONDS - 60
    query = """
        SELECT
          ts,
          ts_nanos,
          target,
          level,
          substr(
            feedback_log_body,
            instr(feedback_log_body, 'run_sampling_request{turn_id=')
              + length('run_sampling_request{turn_id='),
            36
          ) AS turn_id,
          CASE WHEN target IN (?, ?) THEN
            substr(
              feedback_log_body,
              instr(feedback_log_body, ' model=') + length(' model='),
              instr(substr(feedback_log_body, instr(feedback_log_body, ' model=') + length(' model=')), ' ') - 1
            )
          END AS model,
          CASE WHEN target IN (?, ?) THEN
            substr(
              feedback_log_body,
              instr(feedback_log_body, 'codex.turn.reasoning_effort=')
                + length('codex.turn.reasoning_effort='),
              instr(substr(
                feedback_log_body,
                instr(feedback_log_body, 'codex.turn.reasoning_effort=')
                  + length('codex.turn.reasoning_effort=')
              ), '}') - 1
            )
          END AS reasoning_effort
        FROM logs INDEXED BY idx_logs_ts
        WHERE ts >= ?
          AND (
            (target IN (?, ?) AND instr(feedback_log_body, 'run_sampling_request{turn_id=') > 0)
            OR
            (target = ? AND level = 'DEBUG'
             AND instr(feedback_log_body, 'Output item item_type=') > 0)
            OR
            (target = ? AND instr(feedback_log_body, 'stream disconnected') > 0)
          )
        ORDER BY ts ASC, ts_nanos ASC, id ASC
        LIMIT ?
    """
    try:
        uri = f"file:{path}?mode=ro&immutable=0"
        with sqlite3.connect(uri, uri=True, timeout=0.1) as connection:
            connection.execute("PRAGMA query_only = ON")
            deadline = time.monotonic() + 0.1
            connection.set_progress_handler(lambda: int(time.monotonic() > deadline), 1_000)
            rows = connection.execute(
                query,
                (
                    TARGET_WEBSOCKET,
                    TARGET_CLIENT,
                    TARGET_WEBSOCKET,
                    TARGET_CLIENT,
                    cutoff,
                    TARGET_WEBSOCKET,
                    TARGET_CLIENT,
                    TARGET_OUTPUT,
                    TARGET_RETRY,
                    MAX_ROWS,
                ),
            ).fetchall()
        return analyze_codex_rows(rows, now)
    except (sqlite3.Error, OSError) as exc:
        return {"available": False, "active": False, "error": f"Codex 日志不可用: {exc}"}


def _unix_http_request(
    socket_path: str,
    path: str,
    timeout: float = 0.25,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
) -> tuple[int, bytes]:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(socket_path)
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else b""
        headers = [
            f"{method} {path} HTTP/1.1",
            "Host: localhost",
            "Connection: close",
        ]
        if body:
            headers.extend(("Content-Type: application/json", f"Content-Length: {len(body)}"))
        client.sendall(("\r\n".join(headers) + "\r\n\r\n").encode() + body)
        chunks: list[bytes] = []
        while True:
            chunk = client.recv(65_536)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks)
        headers, body = raw.split(b"\r\n\r\n", 1)
        status_line = headers.split(b"\r\n", 1)[0]
        status = int(status_line.split(b" ", 2)[1])
        if b"transfer-encoding: chunked" in headers.lower():
            body = _decode_chunked(body)
        if status >= 400:
            raise OSError(f"mihomo HTTP {status}")
        return status, body
    finally:
        client.close()


def _unix_http_json(socket_path: str, path: str, timeout: float = 0.25) -> dict[str, Any]:
    _, body = _unix_http_request(socket_path, path, timeout=timeout)
    return json.loads(body.decode("utf-8"))


def _decode_chunked(data: bytes) -> bytes:
    output = bytearray()
    offset = 0
    while offset < len(data):
        line_end = data.find(b"\r\n", offset)
        if line_end < 0:
            raise ValueError("invalid chunked response")
        size_text = data[offset:line_end].split(b";", 1)[0]
        size = int(size_text, 16)
        offset = line_end + 2
        if size == 0:
            return bytes(output)
        end = offset + size
        if end > len(data):
            raise ValueError("truncated chunked response")
        output.extend(data[offset:end])
        offset = end + 2
    raise ValueError("unterminated chunked response")


def _run(command: list[str], timeout: float = 0.3) -> str:
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    return result.stdout if result.returncode == 0 else ""


def evaluate_tun(config: dict[str, Any], route_output: str, interface_output: str) -> dict[str, Any]:
    tun = config.get("tun") or {}
    if not tun.get("enable"):
        return {"state": "disabled", "detail": "未开启"}

    device = str(tun.get("device") or "").strip()
    route_match = re.search(r"^\s*interface:\s*(\S+)", route_output, re.MULTILINE)
    route_device = route_match.group(1) if route_match else ""
    interface_up = "<UP," in interface_output or "<UP>" in interface_output
    has_tun_address = bool(re.search(r"\binet\s+198\.18\.", interface_output))

    if not device or route_device != device or not interface_up or not has_tun_address:
        return {"state": "unavailable", "detail": "配置与实际路由不一致"}
    return {"state": "enabled", "detail": f"已开启 · {device}"}


def clash_unavailable_detail(app_paths: tuple[str, ...] = CLASH_APP_PATHS) -> str:
    if any(os.path.exists(path) for path in app_paths):
        return "Clash Verge 未连接"
    return "未安装 Clash Verge"


def read_tun_state(
    socket_path: str = MIHOMO_SOCKET,
    app_paths: tuple[str, ...] = CLASH_APP_PATHS,
) -> dict[str, Any]:
    if not os.path.exists(socket_path):
        return {"state": "unavailable", "detail": clash_unavailable_detail(app_paths)}
    try:
        config = _unix_http_json(socket_path, "/configs")
        tun = config.get("tun") or {}
        device = str(tun.get("device") or "utun4")
        route_output = _run(["/sbin/route", "-n", "get", "198.18.0.10"])
        interface_output = _run(["/sbin/ifconfig", device]) if device else ""
        return evaluate_tun(config, route_output, interface_output)
    except (OSError, ValueError, KeyError, json.JSONDecodeError, subprocess.SubprocessError):
        return {"state": "unavailable", "detail": "TUN 状态不可用"}


def resolve_proxy_state(proxies_payload: dict[str, Any], connections_payload: dict[str, Any]) -> dict[str, Any]:
    """优先取 ChatGPT 活连接的实际叶子节点，无连接时递归解析 AI 策略组。"""
    connections = connections_payload.get("connections") or []
    for connection in connections:
        metadata = connection.get("metadata") or {}
        host = str(metadata.get("host") or "").lower()
        if "chatgpt" not in host and "openai" not in host:
            continue
        chains = [str(item).strip() for item in (connection.get("chains") or []) if str(item).strip()]
        if chains:
            return {"available": True, "name": chains[0], "source": "connection"}

    proxies = proxies_payload.get("proxies") or {}
    candidates = [
        name for name in proxies
        if re.search(r"(^|\W)(ai|openai|chatgpt)(\W|$)", name, re.IGNORECASE)
    ]
    candidates.sort(key=lambda name: (0 if "🤖" in name else 1, len(name)))
    if not candidates:
        return {"available": False, "name": None, "source": "unavailable"}

    current = candidates[0]
    visited: set[str] = set()
    while current and current not in visited:
        visited.add(current)
        item = proxies.get(current) or {}
        selected = str(item.get("now") or "").strip()
        if not selected:
            break
        if selected not in proxies or not (proxies.get(selected) or {}).get("now"):
            return {"available": True, "name": selected, "source": "policy"}
        current = selected
    return {"available": False, "name": None, "source": "unavailable"}


def resolve_gpt_proxy_context(proxies_payload: dict[str, Any]) -> dict[str, Any]:
    """解析 GPT 策略链中可安全切换的最深 Selector 及其叶子节点。"""
    proxies = proxies_payload.get("proxies") or {}
    ai_groups = [
        name for name, item in proxies.items()
        if (item or {}).get("type") == "Selector"
        and re.search(r"(^|\W)(ai|openai|chatgpt)(\W|$)", name, re.IGNORECASE)
    ]
    ai_groups.sort(key=lambda name: (0 if "🤖" in name else 1, len(name)))
    if not ai_groups:
        return {"available": False, "error": "未找到 GPT 代理策略组"}

    current = ai_groups[0]
    selector = current
    visited: set[str] = set()
    while current and current not in visited:
        visited.add(current)
        item = proxies.get(current) or {}
        if item.get("type") == "Selector":
            selector = current
        selected = str(item.get("now") or "")
        if not selected.strip():
            break
        current = selected

    selector_item = proxies.get(selector) or {}
    candidates = []
    for raw_name in selector_item.get("all") or []:
        name = str(raw_name)
        display_name = name.strip()
        item = proxies.get(name) or {}
        if not display_name or item.get("type") in GROUP_PROXY_TYPES or item.get("all"):
            continue
        if re.search(r"香港|hong\s*kong|\bhk\b", display_name, re.IGNORECASE):
            continue
        if re.search(r"direct|reject|pass|直连", display_name, re.IGNORECASE) and "美国" not in display_name:
            continue
        candidates.append(name)

    if not candidates:
        return {"available": False, "error": "没有可测速的非香港 GPT 节点"}
    return {
        "available": True,
        "selector": selector,
        "current_name": current if current else None,
        "candidates": candidates,
    }


def choose_gpt_recommendation(
    current_name: str | None, node_results: list[dict[str, Any]]
) -> dict[str, Any]:
    successful = [item for item in node_results if isinstance(item.get("median_ms"), int)]
    successful.sort(key=lambda item: (item["median_ms"], item.get("max_ms") or 10**9))
    current = next((item for item in successful if item["name"] == current_name), None)
    best = successful[0] if successful else None
    recommended = None
    if best and current and best["name"] != current["name"]:
        required_gain = max(50, round(current["median_ms"] * 0.15))
        if current["median_ms"] - best["median_ms"] >= required_gain:
            recommended = best
    elif best and current is None:
        recommended = best
    return {"current": current, "best": best, "recommended": recommended}


def _probe_gpt_node(socket_path: str, name: str) -> dict[str, Any]:
    encoded_name = urllib.parse.quote(name, safe="")
    encoded_url = urllib.parse.quote(GPT_PROBE_URL, safe="")
    path = (
        f"/proxies/{encoded_name}/delay?url={encoded_url}"
        f"&timeout={GPT_PROBE_TIMEOUT_MS}"
    )
    samples: list[int] = []
    for _ in range(GPT_PROBE_ROUNDS):
        try:
            payload = _unix_http_json(
                socket_path,
                path,
                timeout=GPT_PROBE_TIMEOUT_MS / 1000 + 1,
            )
            delay = payload.get("delay")
            if isinstance(delay, int) and delay > 0:
                samples.append(delay)
        except (OSError, ValueError, KeyError, json.JSONDecodeError, socket.timeout):
            continue
    ordered = sorted(samples)
    return {
        "name": name,
        "median_ms": round(statistics.median(ordered)) if ordered else None,
        "min_ms": ordered[0] if ordered else None,
        "max_ms": ordered[-1] if ordered else None,
        "success_count": len(ordered),
        "sample_count": GPT_PROBE_ROUNDS,
    }


def probe_gpt_nodes(socket_path: str = MIHOMO_SOCKET) -> dict[str, Any]:
    """不改变选择器，让每个候选节点分别访问 ChatGPT 真实端点。"""
    updated = int(time.time())
    if not os.path.exists(socket_path):
        return {"available": False, "updated": updated, "error": "Clash Verge 未连接"}
    try:
        proxies_payload = _unix_http_json(socket_path, "/proxies", timeout=0.5)
        context = resolve_gpt_proxy_context(proxies_payload)
        if not context.get("available"):
            return {**context, "updated": updated}
        candidates = context["candidates"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(5, len(candidates))) as pool:
            results = list(pool.map(lambda name: _probe_gpt_node(socket_path, name), candidates))
        ranking = choose_gpt_recommendation(context.get("current_name"), results)
        return {
            "available": True,
            "updated": updated,
            "probe_url": GPT_PROBE_URL,
            "selector": context["selector"],
            "current_name": context.get("current_name"),
            "current": ranking["current"],
            "recommended": ranking["recommended"],
            "best": ranking["best"],
            "nodes": sorted(
                results,
                key=lambda item: (
                    item["median_ms"] is None,
                    item["median_ms"] if item["median_ms"] is not None else 10**9,
                ),
            ),
        }
    except (OSError, ValueError, KeyError, json.JSONDecodeError, socket.timeout) as exc:
        return {"available": False, "updated": updated, "error": f"GPT 节点测速失败: {exc}"}


def switch_gpt_node(name: str, socket_path: str = MIHOMO_SOCKET) -> dict[str, Any]:
    """仅在明确按钮操作后切换；目标必须仍是当前非香港候选节点。"""
    proxies_payload = _unix_http_json(socket_path, "/proxies", timeout=0.5)
    context = resolve_gpt_proxy_context(proxies_payload)
    target = name
    if not context.get("available") or target not in context.get("candidates", []):
        return {"ok": False, "error": "目标节点不可用或已被排除"}
    selector = context["selector"]
    path = "/proxies/" + urllib.parse.quote(selector, safe="")
    status, _ = _unix_http_request(
        socket_path,
        path,
        timeout=1.0,
        method="PUT",
        payload={"name": target},
    )
    return {"ok": status in (200, 204), "selector": selector, "name": target}


def read_proxy_state(
    socket_path: str = MIHOMO_SOCKET,
    app_paths: tuple[str, ...] = CLASH_APP_PATHS,
) -> dict[str, Any]:
    if not os.path.exists(socket_path):
        return {
            "available": False,
            "name": None,
            "source": "unavailable",
            "detail": clash_unavailable_detail(app_paths),
        }
    try:
        proxies = _unix_http_json(socket_path, "/proxies", timeout=0.4)
        connections = _unix_http_json(socket_path, "/connections", timeout=0.4)
        return resolve_proxy_state(proxies, connections)
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return {
            "available": False,
            "name": None,
            "source": "unavailable",
            "detail": "Clash Verge 状态不可用",
        }


def collect(log_path: str = LOG_PATH, now: float | None = None) -> dict[str, Any]:
    current = time.time() if now is None else now
    return {
        "updated": int(current),
        "tun": read_tun_state(),
        "proxy": read_proxy_state(),
        "codex": read_codex_activity(log_path, current),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log-path", default=LOG_PATH)
    parser.add_argument("--probe-gpt-nodes", action="store_true")
    parser.add_argument("--switch-node")
    args = parser.parse_args()
    if args.switch_node:
        try:
            result = switch_gpt_node(args.switch_node)
        except (OSError, ValueError, KeyError, json.JSONDecodeError, socket.timeout) as exc:
            result = {"ok": False, "error": f"切换失败: {exc}"}
    elif args.probe_gpt_nodes:
        result = probe_gpt_nodes()
    else:
        result = collect(args.log_path)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
