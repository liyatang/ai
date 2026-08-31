#!/usr/bin/env python3
"""Codex 状态本地诊断数据层。

只读取 Codex 性能元数据（时间、模型、reasoning、事件类型、重试）与
Clash/mihomo 本机状态；不输出或缓存提示词、工具参数、工作路径。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import fcntl
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
QUALITY_PATH = os.path.expanduser("~/.config/quota-widget/gpt_node_quality.json")
SWITCH_AUDIT_PATH = os.path.expanduser("~/.config/quota-widget/switch_audit.jsonl")
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
GPT_PROBE_ROUNDS = 5
GPT_PROBE_TIMEOUT_MS = 6_000
GROUP_PROXY_TYPES = frozenset(("Selector", "URLTest", "Fallback", "LoadBalance"))
QUALITY_WINDOW_SECONDS = 86_400
QUALITY_MAX_TURNS = 20
QUALITY_MIN_STABLE_TURNS = 10
SWITCH_GRACE_SECONDS = 30

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
    rows: list[tuple[Any, ...]], now: float
) -> dict[str, Any]:
    """把已经过滤为性能元数据的日志行聚合为最近五分钟活动。"""
    cutoff = now - ACTIVITY_SECONDS
    starts: dict[str, TurnStart] = {}
    first_outputs: dict[str, float] = {}
    last_outputs: dict[str, float] = {}
    retries: dict[str, int] = {}
    retry_times: dict[str, list[float]] = {}
    tls_eofs: dict[str, int] = {}
    closed_connections: dict[str, int] = {}

    for row in rows:
        seconds, nanos, target, level, turn_id, model, effort = row[:7]
        body = str(row[7] or "") if len(row) > 7 else ""
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
            retry_times.setdefault(turn_id, []).append(at)
            if "unexpected-eof" in body or "close_notify" in body:
                tls_eofs[turn_id] = tls_eofs.get(turn_id, 0) + 1
            if "Connection closed" in body or "connection closed" in body:
                closed_connections[turn_id] = closed_connections.get(turn_id, 0) + 1

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
    eligible_ids = {
        turn_id for turn_id in active_ids
        if turn_id in first_outputs or retries.get(turn_id, 0) > 0
    }
    retry_turn_count = sum(1 for turn_id in eligible_ids if retries.get(turn_id, 0) > 0)
    first_attempt_success_count = sum(
        1 for turn_id in eligible_ids
        if turn_id in first_outputs and retries.get(turn_id, 0) == 0
    )
    first_attempt_success_pct = (
        round(first_attempt_success_count / len(eligible_ids) * 100)
        if eligible_ids else None
    )
    ordered_eligible = sorted(
        eligible_ids,
        key=lambda turn_id: starts.get(turn_id, TurnStart(0, None, None)).at,
        reverse=True,
    )
    stable_streak = 0
    for turn_id in ordered_eligible:
        if turn_id in first_outputs and retries.get(turn_id, 0) == 0:
            stable_streak += 1
        else:
            break
    turn_records = []
    for turn_id in active_ids:
        start = starts.get(turn_id)
        if start is None:
            continue
        turn_retry_times = retry_times.get(turn_id, [])
        turn_records.append({
            "turn_id": turn_id,
            "start_at": round(start.at, 6),
            "last_seen_at": round(max(
                [start.at, first_outputs.get(turn_id, start.at), *turn_retry_times]
            ), 6),
            "has_output": turn_id in first_outputs,
            "retry_count": retries.get(turn_id, 0),
            "opening_retry_count": sum(1 for at in turn_retry_times if at - start.at <= 15),
            "tls_eof_count": tls_eofs.get(turn_id, 0),
            "connection_closed_count": closed_connections.get(turn_id, 0),
        })
    return {
        "available": True,
        "active": bool(active_ids),
        "window_seconds": ACTIVITY_SECONDS,
        "turn_count": len(active_ids),
        "sample_count": len(waits),
        "first_output_median_seconds": round(statistics.median(waits), 3) if waits else None,
        "first_output_p90_seconds": round(_percentile(waits, 0.9), 3) if waits else None,
        "retry_count": retry_count,
        "retry_turn_count": retry_turn_count,
        "first_attempt_success_count": first_attempt_success_count,
        "first_attempt_success_pct": first_attempt_success_pct,
        "max_retries_per_turn": max((retries.get(turn_id, 0) for turn_id in eligible_ids), default=0),
        "opening_retry_count": sum(
            1 for turn_id in eligible_ids for at in retry_times.get(turn_id, [])
            if at - starts[turn_id].at <= 15
        ),
        "tls_eof_count": sum(tls_eofs.get(turn_id, 0) for turn_id in eligible_ids),
        "connection_closed_count": sum(
            closed_connections.get(turn_id, 0) for turn_id in eligible_ids
        ),
        "stable_streak": stable_streak,
        "model": latest.model if latest else None,
        "reasoning_effort": latest.reasoning_effort if latest else None,
        "_turns": turn_records,
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
          END AS reasoning_effort,
          CASE WHEN target = ? THEN feedback_log_body END AS retry_detail
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
                    TARGET_RETRY,
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
    """同时返回 selector 选中节点与现有 ChatGPT 活连接的实际叶子节点。"""
    connections = connections_payload.get("connections") or []
    active_name = None
    for connection in connections:
        metadata = connection.get("metadata") or {}
        host = str(metadata.get("host") or "").lower()
        if "chatgpt" not in host and "openai" not in host:
            continue
        chains = [str(item).strip() for item in (connection.get("chains") or []) if str(item).strip()]
        if chains:
            active_name = chains[0]
            break

    proxies = proxies_payload.get("proxies") or {}
    candidates = [
        name for name in proxies
        if re.search(r"(^|\W)(ai|openai|chatgpt)(\W|$)", name, re.IGNORECASE)
    ]
    candidates.sort(key=lambda name: (0 if "🤖" in name else 1, len(name)))
    if not candidates:
        return {
            "available": active_name is not None,
            "name": active_name,
            "selected_name": None,
            "active_name": active_name,
            "transitioning": False,
            "source": "connection" if active_name else "unavailable",
        }

    current = candidates[0]
    visited: set[str] = set()
    selected_name = None
    while current and current not in visited:
        visited.add(current)
        item = proxies.get(current) or {}
        selected = str(item.get("now") or "").strip()
        if not selected:
            break
        if selected not in proxies or not (proxies.get(selected) or {}).get("now"):
            selected_name = selected
            break
        current = selected
    name = selected_name or active_name
    return {
        "available": name is not None,
        "name": name,
        "selected_name": selected_name,
        "active_name": active_name,
        "transitioning": bool(
            selected_name and active_name and selected_name.strip() != active_name.strip()
        ),
        "source": "policy" if selected_name else ("connection" if active_name else "unavailable"),
    }


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


def load_quality_history(
    path: str = QUALITY_PATH, now: float | None = None
) -> dict[str, Any]:
    current = time.time() if now is None else now
    try:
        with open(path, encoding="utf-8") as file:
            payload = json.load(file)
        if not isinstance(payload, dict) or payload.get("version") != 1:
            raise ValueError("unsupported quality history")
        payload.setdefault("created_at", current)
        payload.setdefault("turns", {})
        payload.setdefault("switches", [])
        return payload
    except (OSError, ValueError, json.JSONDecodeError):
        return {
            "version": 1,
            "created_at": current,
            "updated": current,
            "turns": {},
            "switches": [],
        }


@contextlib.contextmanager
def quality_history_lock(path: str = QUALITY_PATH):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor = os.open(f"{path}.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def save_quality_history(history: dict[str, Any], path: str = QUALITY_PATH) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    temporary = f"{path}.tmp-{os.getpid()}"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            json.dump(history, file, ensure_ascii=False, separators=(",", ":"))
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def record_node_switch(
    previous: str | None,
    target: str,
    at: float | None = None,
    path: str = QUALITY_PATH,
) -> None:
    changed_at = time.time() if at is None else at
    with quality_history_lock(path):
        history = load_quality_history(path, changed_at)
        history["switches"] = [
            item for item in history.get("switches", [])
            if changed_at - float(item.get("at") or 0) <= QUALITY_WINDOW_SECONDS
        ]
        history["switches"].append({"at": changed_at, "from": previous, "to": target})
        history["updated"] = changed_at
        save_quality_history(history, path)


def record_switch_audit(
    entry: dict[str, Any], path: str = SWITCH_AUDIT_PATH, limit: int = 100
) -> None:
    """原子保存最近的本地切换结果，不包含请求内容或认证信息。"""
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    lock_descriptor = os.open(f"{path}.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        lines: list[str] = []
        try:
            with open(path, encoding="utf-8") as file:
                lines = file.read().splitlines()[-max(0, limit - 1):]
        except OSError:
            pass
        lines.append(json.dumps(entry, ensure_ascii=False, separators=(",", ":")))
        temporary = f"{path}.tmp-{os.getpid()}"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as file:
                file.write("\n".join(lines) + "\n")
            os.replace(temporary, path)
            os.chmod(path, 0o600)
        except BaseException:
            try:
                os.unlink(temporary)
            except OSError:
                pass
            raise
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def _node_for_turn(
    start_at: float, current_name: str, switches: list[dict[str, Any]]
) -> str:
    ordered = sorted(switches, key=lambda item: float(item.get("at") or 0))
    node = current_name
    for item in ordered:
        switched_at = float(item.get("at") or 0)
        if start_at < switched_at:
            previous = item.get("from")
            return str(previous) if previous else node
        target = item.get("to")
        if target:
            node = str(target)
    return node


def update_quality_history(
    history: dict[str, Any],
    current_name: str | None,
    turns: list[dict[str, Any]],
    now: float,
) -> dict[str, Any]:
    cutoff = now - QUALITY_WINDOW_SECONDS
    created_at = float(history.get("created_at") or now)
    switches = [
        item for item in history.get("switches", [])
        if float(item.get("at") or 0) >= cutoff
    ]
    stored = {
        turn_id: item for turn_id, item in (history.get("turns") or {}).items()
        if float((item or {}).get("last_seen_at") or 0) >= cutoff
    }
    if current_name:
        for turn in turns:
            turn_id = str(turn.get("turn_id") or "")
            start_at = float(turn.get("start_at") or 0)
            if not turn_id or start_at < created_at or start_at < cutoff:
                continue
            previous = stored.get(turn_id) or {}
            node = str(previous.get("node") or _node_for_turn(start_at, current_name, switches))
            last_seen_at = float(turn.get("last_seen_at") or start_at)
            overlaps_switch = any(
                start_at <= float(item.get("at") or 0) + SWITCH_GRACE_SECONDS
                and last_seen_at >= float(item.get("at") or 0) - 5
                for item in switches
            )
            stored[turn_id] = {
                "node": node,
                "start_at": start_at,
                "last_seen_at": last_seen_at,
                "has_output": bool(turn.get("has_output")),
                "retry_count": int(turn.get("retry_count") or 0),
                "opening_retry_count": int(turn.get("opening_retry_count") or 0),
                "tls_eof_count": int(turn.get("tls_eof_count") or 0),
                "connection_closed_count": int(turn.get("connection_closed_count") or 0),
                "ignored_after_switch": bool(previous.get("ignored_after_switch")) or overlaps_switch,
            }
    history.update({
        "version": 1,
        "created_at": created_at,
        "updated": now,
        "turns": stored,
        "switches": switches,
    })
    return history


def summarize_node_quality(
    history: dict[str, Any], node: str, now: float | None = None
) -> dict[str, Any]:
    current = time.time() if now is None else now
    records = [
        item for item in (history.get("turns") or {}).values()
        if (item or {}).get("node") == node
        and not (item or {}).get("ignored_after_switch")
        and current - float((item or {}).get("start_at") or 0) <= QUALITY_WINDOW_SECONDS
        and (
            (item or {}).get("has_output")
            or int((item or {}).get("retry_count") or 0) > 0
            or current - float((item or {}).get("start_at") or 0) > ACTIVITY_SECONDS
        )
    ]
    records.sort(key=lambda item: float(item.get("start_at") or 0), reverse=True)
    records = records[:QUALITY_MAX_TURNS]
    turn_count = len(records)
    retry_turn_count = sum(1 for item in records if int(item.get("retry_count") or 0) > 0)
    retry_count = sum(int(item.get("retry_count") or 0) for item in records)
    first_attempt_success_count = sum(
        1 for item in records
        if item.get("has_output") and int(item.get("retry_count") or 0) == 0
    )
    first_attempt_success_pct = (
        round(first_attempt_success_count / turn_count * 100) if turn_count else None
    )
    max_retries = max((int(item.get("retry_count") or 0) for item in records), default=0)
    tls_eof_count = sum(int(item.get("tls_eof_count") or 0) for item in records)
    connection_closed_count = sum(
        int(item.get("connection_closed_count") or 0) for item in records
    )
    hard_failure_count = sum(
        1 for item in records
        if not item.get("has_output")
        and current - float(item.get("start_at") or 0) > ACTIVITY_SECONDS
    )
    stable_streak = 0
    for item in records:
        if item.get("has_output") and int(item.get("retry_count") or 0) == 0:
            stable_streak += 1
        else:
            break
    retry_turn_pct = round(retry_turn_count / turn_count * 100) if turn_count else 0
    severe = max_retries >= 3 or tls_eof_count >= 2 or hard_failure_count > 0
    unstable_by_rate = (
        (turn_count >= 5 and retry_turn_pct >= 20)
        or (turn_count >= QUALITY_MIN_STABLE_TURNS and retry_turn_pct >= 10)
    )
    if severe or unstable_by_rate:
        status = "unstable"
    elif (
        turn_count >= QUALITY_MIN_STABLE_TURNS
        and first_attempt_success_pct is not None
        and first_attempt_success_pct >= 95
    ):
        status = "stable"
    else:
        status = "observing"
    confidence = "high" if turn_count >= 20 else ("medium" if turn_count >= 10 else "low")
    return {
        "node": node,
        "status": status,
        "confidence": confidence,
        "turn_count": turn_count,
        "required_turn_count": QUALITY_MIN_STABLE_TURNS,
        "first_attempt_success_pct": first_attempt_success_pct,
        "retry_turn_count": retry_turn_count,
        "retry_turn_pct": retry_turn_pct,
        "retry_count": retry_count,
        "max_retries_per_turn": max_retries,
        "opening_retry_count": sum(int(item.get("opening_retry_count") or 0) for item in records),
        "tls_eof_count": tls_eof_count,
        "connection_closed_count": connection_closed_count,
        "hard_failure_count": hard_failure_count,
        "stable_streak": stable_streak,
    }


def all_node_qualities(
    history: dict[str, Any], now: float | None = None
) -> dict[str, dict[str, Any]]:
    nodes = {
        str(item.get("node")) for item in (history.get("turns") or {}).values()
        if (item or {}).get("node")
    }
    return {node: summarize_node_quality(history, node, now) for node in nodes}


def choose_gpt_recommendation(
    current_name: str | None,
    node_results: list[dict[str, Any]],
    node_qualities: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    qualities = node_qualities or {}
    successful = [
        item for item in node_results
        if isinstance(item.get("median_ms"), int)
        and item.get("success_count") == item.get("sample_count")
    ]
    successful.sort(key=lambda item: (
        item.get("p90_ms") or 10**9,
        item["median_ms"],
        item.get("max_ms") or 10**9,
    ))
    current = next((item for item in successful if item["name"] == current_name), None)
    best = successful[0] if successful else None
    recommended = None
    trial = None
    current_quality = qualities.get(current_name or "") or {
        "node": current_name,
        "status": "observing",
        "confidence": "low",
        "turn_count": 0,
        "required_turn_count": QUALITY_MIN_STABLE_TURNS,
    }
    current_status = current_quality.get("status")
    if current is None and current_name:
        current_status = "unavailable"
        current_quality = {**current_quality, "status": "unavailable"}
    if current_status in ("unstable", "unavailable"):
        stable_candidates = [
            item for item in successful
            if item.get("name") != current_name
            and (qualities.get(str(item.get("name"))) or {}).get("status") == "stable"
        ]
        stable_candidates.sort(key=lambda item: (
            -(qualities[str(item["name"])].get("first_attempt_success_pct") or 0),
            item.get("p90_ms") or 10**9,
            item.get("median_ms") or 10**9,
        ))
        recommended = stable_candidates[0] if stable_candidates else None
        if recommended is None:
            trial = next(
                (item for item in successful
                 if item.get("name") != current_name
                 and (qualities.get(str(item.get("name"))) or {}).get("status") != "unstable"),
                None,
            )
    return {
        "current": current,
        "best": best,
        "recommended": recommended,
        "trial": trial,
        "current_quality": current_quality,
        "recommendation_kind": "stable" if recommended else ("trial" if trial else None),
    }


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
        "p90_ms": round(_percentile(ordered, 0.9)) if ordered else None,
        "min_ms": ordered[0] if ordered else None,
        "max_ms": ordered[-1] if ordered else None,
        "success_count": len(ordered),
        "sample_count": GPT_PROBE_ROUNDS,
        "success_pct": round(len(ordered) / GPT_PROBE_ROUNDS * 100),
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
        history = load_quality_history()
        qualities = all_node_qualities(history, updated)
        for item in results:
            item["quality"] = qualities.get(item["name"]) or summarize_node_quality(
                history, item["name"], updated
            )
        ranking = choose_gpt_recommendation(context.get("current_name"), results, qualities)
        return {
            "available": True,
            "updated": updated,
            "probe_url": GPT_PROBE_URL,
            "selector": context["selector"],
            "current_name": context.get("current_name"),
            "current": ranking["current"],
            "recommended": ranking["recommended"],
            "trial": ranking["trial"],
            "best": ranking["best"],
            "current_quality": ranking["current_quality"],
            "recommendation_kind": ranking["recommendation_kind"],
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


def switch_gpt_node(
    name: str,
    socket_path: str = MIHOMO_SOCKET,
    quality_path: str | None = QUALITY_PATH,
    audit_path: str | None = SWITCH_AUDIT_PATH,
) -> dict[str, Any]:
    """仅在明确按钮操作后切换，并回读 selector 确认实际结果。"""
    proxies_payload = _unix_http_json(socket_path, "/proxies", timeout=0.5)
    context = resolve_gpt_proxy_context(proxies_payload)
    target = name
    previous = context.get("current_name")
    if not context.get("available") or target not in context.get("candidates", []):
        result = {
            "ok": False,
            "name": target,
            "previous_name": previous,
            "actual_name": previous,
            "error": "目标节点不可用或已被排除",
        }
        if audit_path:
            record_switch_audit({"at": int(time.time()), **result}, path=audit_path)
        return result
    selector = context["selector"]
    path = "/proxies/" + urllib.parse.quote(selector, safe="")
    status, _ = _unix_http_request(
        socket_path,
        path,
        timeout=1.0,
        method="PUT",
        payload={"name": target},
    )
    accepted = status in (200, 204)
    actual = None
    error = None
    if accepted:
        try:
            confirmed_payload = _unix_http_json(socket_path, "/proxies", timeout=0.5)
            confirmed = resolve_gpt_proxy_context(confirmed_payload)
            actual = confirmed.get("current_name")
        except (OSError, ValueError, KeyError, json.JSONDecodeError, socket.timeout):
            error = "切换请求已发送，但无法回读确认"
    ok = accepted and actual == target
    if accepted and actual is not None and actual != target:
        error = f"selector 实际仍为 {str(actual).strip()}"
    if ok and quality_path and previous != target:
        record_node_switch(previous, target, path=quality_path)
    result = {
        "ok": ok,
        "selector": selector,
        "name": target,
        "previous_name": previous,
        "actual_name": actual,
        **({"error": error or "切换未确认"} if not ok else {}),
    }
    if audit_path:
        record_switch_audit({"at": int(time.time()), **result}, path=audit_path)
    return result


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
    proxy = read_proxy_state()
    codex = read_codex_activity(log_path, current)
    turns = codex.pop("_turns", [])
    quality = None
    quality_node = proxy.get("selected_name") or proxy.get("name")
    if proxy.get("available") and quality_node:
        try:
            with quality_history_lock():
                history = load_quality_history(now=current)
                update_quality_history(history, str(quality_node), turns, current)
                save_quality_history(history)
            quality = summarize_node_quality(history, str(quality_node), current)
        except OSError:
            quality = None
    return {
        "updated": int(current),
        "tun": read_tun_state(),
        "proxy": proxy,
        "codex": codex,
        "gpt_quality": quality,
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
