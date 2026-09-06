"""Read-only mihomo adapters. No selector/configuration writes."""
from __future__ import annotations
import json, os, re, socket, subprocess, time, hashlib, urllib.parse
from typing import Any

MIHOMO_SOCKET = "/tmp/verge/verge-mihomo.sock"
CLASH_APP_PATHS = ("/Applications/Clash Verge.app", "/Applications/Clash Verge Rev.app", os.path.expanduser("~/Applications/Clash Verge.app"))
GROUP_PROXY_TYPES = frozenset(("Selector", "URLTest", "Fallback", "LoadBalance"))
GPT_PROBE_URL = "https://chatgpt.com/cdn-cgi/trace"

def _unix_http_request(
    socket_path: str,
    path: str,
    timeout: float = 0.25,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
) -> tuple[int, bytes]:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    deadline = time.monotonic() + timeout
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
            client.settimeout(max(0.001, deadline - time.monotonic()))
            chunk = client.recv(65_536)
            if sum(map(len, chunks)) > 16_000_000:
                raise ValueError("controller response too large")
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



def resolve_proxy_state(proxies_payload, connections_payload, configured_group=None):
    proxies = proxies_payload.get('proxies') or {}
    routes = set()
    for connection in connections_payload.get('connections') or []:
        host = str((connection.get('metadata') or {}).get('host') or '').lower().rstrip('.')
        if not any(host == domain or host.endswith('.' + domain)
                   for domain in ('chatgpt.com', 'openai.com')):
            continue
        chain = tuple(str(x) for x in connection.get('chains') or [] if x)
        if chain:
            routes.add(chain)
    leaves = {chain[0] for chain in routes}
    selectors = {next((n for n in chain[1:] if (proxies.get(n) or {}).get('type') == 'Selector'), None)
                 for chain in routes}
    selectors.discard(None)
    group = next(iter(selectors)) if len(selectors) == 1 else None
    if not routes and configured_group in proxies:
        group = configured_group
    active = next(iter(leaves)) if len(leaves) == 1 else None
    selected, visited = group, set()
    while selected and selected not in visited:
        visited.add(selected)
        item = proxies.get(selected) or {}
        if item.get('type') == 'LoadBalance':
            selected = None
            break
        nxt = item.get('now')
        if not nxt:
            if item.get('all'):
                selected = None
            break
        selected = nxt
    if selected in visited and (proxies.get(selected) or {}).get('now') in visited:
        selected = None
    ambiguous = len(leaves) > 1 or len(selectors) > 1
    transitioning = bool(active and selected and active != selected)
    certain = bool(group and selected and active == selected and not ambiguous)
    detail = ('多条连接路由不一致' if ambiguous else '旧连接收尾' if transitioning else
              '已观察到一致路由' if certain else '等待实际连接，归属尚未确认')
    return dict(available=bool(active or selected), name=selected or active,
                selected_name=selected, active_name=active, selector=group,
                transitioning=transitioning, certain=certain, detail=detail)


def resolve_gpt_proxy_context(proxies_payload, connections_payload=None, configured_group=None):
    state = resolve_proxy_state(proxies_payload, connections_payload or {}, configured_group)
    if not state['certain']:
        return dict(available=False, error=state['detail'], **{k:state[k] for k in ('selector','selected_name')})
    proxies = proxies_payload.get('proxies') or {}
    candidates, seen = [], set()
    def visit(name):
        if name in seen:
            return
        seen.add(name)
        item = proxies.get(name) or {}
        if item.get('all'):
            for child in item['all']:
                visit(child)
        elif item and item.get('type') not in GROUP_PROXY_TYPES and item.get('type') not in ('Direct','Reject','Compatible','Pass'):
            if not re.search(r'香港|hong\s*kong|\bhk\b|直连|direct|reject', name, re.I):
                candidates.append(name)
    visit(state['selector'])
    return dict(available=bool(candidates), error=None if candidates else '没有可测速的候选节点',
                selector=state['selector'], current_name=state['selected_name'], candidates=candidates)


def read_proxy_snapshot(socket_path=MIHOMO_SOCKET, configured_group=None):
    try:
        proxies = _unix_http_json(socket_path, '/proxies', timeout=1)
        connections = _unix_http_json(socket_path, '/connections', timeout=1)
        state = resolve_proxy_state(proxies, connections, configured_group)
        stat = os.stat(socket_path)
        # Dynamic histories, alive and now values are deliberately excluded from the environment.
        topology = sorted((n, v.get('type'), tuple(v.get('all') or []), v.get('id')) for n,v in proxies.get('proxies',{}).items())
        environment = hashlib.sha256(json.dumps([stat.st_ino, stat.st_ctime_ns, topology], ensure_ascii=False).encode()).hexdigest()[:24]
        state['environment'] = environment
        state['identity_confirmed'] = bool((proxies.get('proxies',{}).get(state.get('selected_name')) or {}).get('id'))
        state['node_id'] = (proxies.get('proxies',{}).get(state.get('selected_name')) or {}).get('id')
        state['connection_ids'] = [hashlib.sha256(str(c.get('id')).encode()).hexdigest()[:24] for c in connections.get('connections',[]) if any((str((c.get('metadata') or {}).get('host') or '').lower()==domain or str((c.get('metadata') or {}).get('host') or '').lower().endswith('.'+domain)) for domain in ('chatgpt.com','openai.com'))]
        return state, proxies, connections
    except (OSError, ValueError, KeyError, TypeError):
        return dict(available=False, certain=False, environment='unavailable', detail=clash_unavailable_detail()), {}, {}


def probe_node(name, socket_path=MIHOMO_SOCKET, deadline=None):
    values = []
    attempted = 0
    for _ in range(5):
        if deadline is not None and time.monotonic() >= deadline:
            break
        attempted += 1
        path = '/proxies/' + urllib.parse.quote(name, safe='') + '/delay?url=' + urllib.parse.quote(GPT_PROBE_URL, safe='') + '&timeout=6000&expected=200'
        try:
            result = _unix_http_json(socket_path, path, timeout=min(7, max(.01, deadline-time.monotonic())) if deadline else 7)
            value = result.get('delay')
            if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                values.append(value)
        except (OSError, ValueError, KeyError, TypeError):
            pass
    values.sort()
    return dict(name=name, sample_count=attempted, success_count=len(values),
                median_ms=values[len(values)//2] if values else None,
                p90_ms=values[round((len(values)-1)*.9)] if values else None)
