#!/usr/bin/env python3
"""Codex 状态本地诊断数据层。

只读取 Codex 性能元数据（时间、模型、reasoning、事件类型、重试）与
Clash/mihomo 本机状态；不输出或缓存提示词、工具参数、工作路径。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sqlite3
import statistics
import subprocess
import time
from dataclasses import dataclass
from typing import Any


LOG_PATH = os.path.expanduser("~/.codex/logs_2.sqlite")
MIHOMO_SOCKET = "/tmp/verge/verge-mihomo.sock"
ACTIVITY_SECONDS = 300
MAX_ROWS = 20_000

TARGET_WEBSOCKET = "codex_api::endpoint::responses_websocket"
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
    retries: dict[str, int] = {}

    for seconds, nanos, target, level, turn_id, model, effort in rows:
        if not re.fullmatch(r"[0-9a-f-]{36}", turn_id or ""):
            continue
        at = _timestamp(seconds, nanos)

        if target == TARGET_WEBSOCKET:
            previous = starts.get(turn_id)
            if previous is None or at < previous.at:
                starts[turn_id] = TurnStart(at=at, model=model, reasoning_effort=effort)
        elif target == TARGET_OUTPUT and level == "DEBUG":
            first_outputs[turn_id] = min(first_outputs.get(turn_id, at), at)
        elif target == TARGET_RETRY:
            retries[turn_id] = retries.get(turn_id, 0) + 1

    recent = {turn_id: start for turn_id, start in starts.items() if start.at >= cutoff}
    waits: list[float] = []
    for turn_id, start in recent.items():
        output_at = first_outputs.get(turn_id)
        if output_at is None:
            continue
        wait = output_at - start.at
        if 0 <= wait <= ACTIVITY_SECONDS:
            waits.append(wait)

    latest = max(recent.values(), key=lambda item: item.at) if recent else None
    retry_count = sum(retries.get(turn_id, 0) for turn_id in recent)
    return {
        "available": True,
        "active": bool(recent),
        "window_seconds": ACTIVITY_SECONDS,
        "turn_count": len(recent),
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
          CASE WHEN target = ? THEN
            substr(
              feedback_log_body,
              instr(feedback_log_body, ' model=') + length(' model='),
              instr(substr(feedback_log_body, instr(feedback_log_body, ' model=') + length(' model=')), ' ') - 1
            )
          END AS model,
          CASE WHEN target = ? THEN
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
            (target = ? AND instr(feedback_log_body, 'run_sampling_request{turn_id=') > 0)
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
                    TARGET_WEBSOCKET,
                    cutoff,
                    TARGET_WEBSOCKET,
                    TARGET_OUTPUT,
                    TARGET_RETRY,
                    MAX_ROWS,
                ),
            ).fetchall()
        return analyze_codex_rows(rows, now)
    except (sqlite3.Error, OSError) as exc:
        return {"available": False, "active": False, "error": f"Codex 日志不可用: {exc}"}


def _unix_http_json(socket_path: str, path: str, timeout: float = 0.25) -> dict[str, Any]:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(socket_path)
        client.sendall(
            f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode()
        )
        chunks: list[bytes] = []
        while True:
            chunk = client.recv(65_536)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks)
        headers, body = raw.split(b"\r\n\r\n", 1)
        if b"transfer-encoding: chunked" in headers.lower():
            body = _decode_chunked(body)
        return json.loads(body.decode("utf-8"))
    finally:
        client.close()


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


def read_tun_state(socket_path: str = MIHOMO_SOCKET) -> dict[str, Any]:
    if not os.path.exists(socket_path):
        return {"state": "unavailable", "detail": "无法连接 mihomo"}
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


def read_proxy_state(socket_path: str = MIHOMO_SOCKET) -> dict[str, Any]:
    if not os.path.exists(socket_path):
        return {"available": False, "name": None, "source": "unavailable"}
    try:
        proxies = _unix_http_json(socket_path, "/proxies", timeout=0.4)
        connections = _unix_http_json(socket_path, "/connections", timeout=0.4)
        return resolve_proxy_state(proxies, connections)
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return {"available": False, "name": None, "source": "unavailable"}


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
    args = parser.parse_args()
    print(json.dumps(collect(args.log_path), ensure_ascii=False))


if __name__ == "__main__":
    main()
