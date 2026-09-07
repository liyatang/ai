"""Bounded, read-only DNS checks. Store categories, never controller error bodies."""
from __future__ import annotations
import concurrent.futures
import ipaddress
import json
import time
import urllib.parse
from status_proxy import MIHOMO_SOCKET, _unix_http_request, _unix_http_json, dns_environment_stamp

DOMAINS = ('chatgpt.com', 'ws.chatgpt.com', 'api.openai.com')


def classify_dns(status, body):
    if not isinstance(body, dict):
        return 'unavailable', 'invalid_response'
    # Mihomo can return an explicit upstream failure in an HTTP 500 body.
    message = str(body.get('message', '')).lower()
    if 'all dns requests failed' in message:
        return 'error', 'upstream_timeout' if ('deadline exceeded' in message or 'timeout' in message) else 'upstream_failed'
    if status != 200:
        return 'unavailable', 'controller_error'
    rcode = body.get('Status')
    if type(rcode) is not int:
        return 'unavailable', 'invalid_response'
    if rcode != 0:
        return 'error', {2: 'servfail', 3: 'nxdomain', 5: 'refused'}.get(rcode, 'dns_error')
    # CNAME-only/empty A responses do not establish failure (e.g. IPv6-only host).
    for answer in body.get('Answer') or []:
        if isinstance(answer, dict) and answer.get('type') in (1, 28):
            try:
                ipaddress.ip_address(answer.get('data'))
                return 'ok', 'resolved'
            except (ValueError, TypeError):
                pass
    return 'unavailable', 'no_address_evidence'


def domain_route(domain, connections):
    routes = {tuple(c.get('chains') or []) for c in connections.get('connections', [])
              if str((c.get('metadata') or {}).get('host', '')).lower().rstrip('.') == domain}
    if len(routes) != 1:
        return 'unknown'
    chain = next(iter(routes))
    if not chain:
        return 'unknown'
    if chain[0].upper() == 'DIRECT':
        return 'direct'
    if chain[0].upper() in ('REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE'):
        return 'unknown'
    return 'proxy'


def check_dns(payload=None, socket_path=MIHOMO_SOCKET):
    payload = payload or {}
    deadline = time.monotonic() + 5
    stamp = dns_environment_stamp(socket_path)
    try:
        connections = _unix_http_json(socket_path, '/connections', timeout=.4)
    except (OSError, ValueError, TypeError):
        connections = {}

    def query(domain):
        result = dict(domain=domain, route=domain_route(domain, connections))
        try:
            path = '/dns/query?' + urllib.parse.urlencode({'name': domain, 'type': 'A'})
            status, raw = _unix_http_request(socket_path, path,
                timeout=min(3, max(.001, deadline-time.monotonic())), raise_for_status=False)
            state, code = classify_dns(status, json.loads(raw))
        except (OSError, ValueError, TypeError):
            state, code = 'unavailable', 'controller_unavailable'
        return dict(result, state=state, code=code, observed_at=time.time())

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(query, DOMAINS))
    unchanged = stamp == dns_environment_stamp(socket_path)
    return dict(epoch=payload.get('epoch'), observed_at=time.time(), environment=stamp,
                state='ok' if unchanged else 'unavailable',
                interval=60 if payload.get('dns_interval') == 60 else 120,
                results=results if unchanged else [])
