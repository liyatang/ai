"""Pure facts/diagnosis projection. History cannot make the current state red."""
from __future__ import annotations


def project(events, proxy, source, probe, previous, now, epoch_started, dns=None):
    recent = [e for e in events if now-300 <= e['at'] <= now and e['at'] >= epoch_started]
    retries = [e for e in recent if e['kind']=='retry']
    outputs = {}
    for e in recent:
        if e['kind']=='output' and e.get('task'):
            outputs[e['task']] = max(outputs.get(e['task'],0),e['at'])
    unresolved = [e for e in retries if not e.get('task') or outputs.get(e['task'],0) <= e['at']]
    valid = source.get('state')=='ok' and 0 <= now-source.get('observed_at',0)<=45
    route_ok = proxy.get('certain',False) and proxy.get('identity_confirmed',False)
    same = previous.get('epoch_started')==epoch_started
    condition = valid and len(unresolved)>=3
    # Separate collections at least ten seconds apart; manual reentry cannot promote an alert.
    prior_at = previous.get('confirmation_at',0) if same else 0
    confirmations = previous.get('confirmations',0) if same else 0
    if not condition:
        confirmations,prior_at = 0,0
    elif confirmations==0 or now-prior_at>=10:
        confirmations += 1
        prior_at = now
    sustained = condition and confirmations>=2
    pvalid = probe.get('state')=='ok' and 0<=now-probe.get('observed_at',0)<=probe.get('interval',120)*2
    samples = [x for x in probe.get('samples',[]) if epoch_started<=x.get('at',0)<=now
               and now-x['at']<=probe.get('interval',120)*4]
    samples.sort(key=lambda x:x['at'])
    failed = previous.get('probe_failed',False) if same and pvalid else False
    if pvalid and len(samples)>=3 and all(not s['ok'] for s in samples[-3:]):
        failed=True
    if pvalid and len(samples)>=2 and all(s['ok'] for s in samples[-2:]):
        failed=False
    status,severity,title,advice='unknown','neutral','暂无活动样本','等待有效样本'
    if sustained:
        status,severity,title,advice='sustained','danger','连接持续异常','可手动尝试其他节点'
    elif failed:
        status,severity,title,advice='probe_failed','warning','ChatGPT 探针访问异常','检查代理与网络连接'
    elif not valid:
        title='连接数据不可用' if source.get('state')=='unavailable' else '连接证据不足'
        advice='等待采集恢复'
    elif unresolved:
        status,severity,title,advice='retrying','warning','观察到后台重试','继续观察恢复情况'
    elif retries:
        status,severity,title,advice='recovered','good','重试后已继续输出','无需调整，继续观察'
    elif recent:
        status,severity,title,advice='clear','good','近期未见异常','无需调整，继续使用'
    activity = ('重试后已继续输出' if retries and not unresolved else '最近有输出' if outputs else
                '观察到后台重试' if retries else '等待输出，原因未确认' if recent else '暂无活动样本')
    if not valid:
        activity='采集不可用' if source.get('state')=='unavailable' else '证据不完整'
    if proxy.get('transitioning'):
        advice='旧连接收尾，继续观察'
    elif not route_ok and status in ('sustained','probe_failed','retrying'):
        advice='先确认当前代理路由'
    network = project_network(dns or {}, probe, previous.get('dns_state', {}) if same else {}, now, epoch_started)
    if network['alerts']:
        if not sustained:
            status,severity,title = 'dns_failed','warning',network['title']
        advice='检查 Clash DNS 设置及上游可达性'
    elif network['tls_failed'] and not sustained:
        status,severity,title,advice='tls_failed','warning','TLS 握手异常','检查 TLS 连接与代理链路'
    historical = [e for e in events if e['kind']=='retry' and now-86400 <= e['at']<=now]
    return dict(status=status,severity=severity,title=title,
                short_title='连接异常 · DNS 解析失败' if status=='dns_failed' and title.startswith('连接异常') else None,
                advice=advice,activity=activity,
                retry_count=len(retries) if valid else None,unresolved_count=len(unresolved),
                history_count=len(historical),last_retry_at=max((e['at'] for e in historical),default=None),
                active=bool(recent),can_compare=bool(valid and route_ok and (sustained or failed) and not network['alerts'] and not network['tls_failed']),
                evidence=[source.get('error') or '近期日志事件',proxy.get('detail') or '路由未知',
                          '后台重试不代表任务重新开始','短请求探针不代表模型速度'] + network['evidence'],
                state=dict(confirmations=confirmations,confirmation_at=prior_at,
                           probe_failed=failed,epoch_started=epoch_started,dns_state=network['state']))


def rank_candidates(results, current, usage):
    eligible=[r for r in results if r['name']!=current and r.get('sample_count')==5
              and r.get('success_count')==5 and r.get('median_ms') is not None]
    eligible.sort(key=lambda r:(-usage.get(r['name'],0),r.get('p90_ms',10**9),r['median_ms'],r['name']))
    return eligible[0] if eligible else None


DNS_CODES = {'resolved':'解析成功', 'upstream_timeout':'上游 DNS 超时',
             'upstream_failed':'上游 DNS 请求失败', 'servfail':'DNS SERVFAIL',
             'nxdomain':'DNS NXDOMAIN', 'refused':'DNS 拒绝解析', 'dns_error':'DNS 返回错误',
             'controller_unavailable':'DNS 检测不可用', 'controller_error':'DNS 控制器接口不可用',
             'invalid_response':'DNS 响应无法识别', 'no_address_evidence':'缺少地址解析证据'}
STAGES = {'dns':'DNS 解析失败', 'connect':'连接失败', 'tls':'TLS 握手失败',
          'timeout':'请求超时（阶段未确认）', 'response_timeout':'响应超时',
          'http':'HTTP 响应', 'unknown':'连接失败，原因未确认'}


def project_network(dns, probe, previous, now, epoch_started):
    from status_dns import DOMAINS
    import time
    evidence, states, alerts = [], {}, []
    def fresh(at, interval):
        return isinstance(at, (int, float)) and epoch_started <= at <= now and now-at <= interval*2
    interval = 60 if dns.get('interval') == 60 else 120
    dns_valid = dns.get('state') == 'ok' and fresh(dns.get('observed_at'), interval)
    pinterval = 30 if probe.get('interval') == 30 else 120
    probe_valid = probe.get('state') == 'ok' and fresh(probe.get('observed_at'), pinterval)
    samples = sorted([s for s in probe.get('samples', [])
                      if probe_valid and fresh(s.get('at'), pinterval*2)], key=lambda s:s['at'])
    # An HTTP rejection is a response, not a DNS/TLS/transport failure.
    latest = {s.get('domain'):s for s in samples}
    failures = {domain for domain,s in latest.items() if s.get('ok') is False and s.get('stage') != 'http'}
    if not dns_valid:
        evidence.append('DNS 检测不可用或已过期；不参与当前判断')
    for result in dns.get('results', []) if dns_valid else []:
        domain = result.get('domain')
        if domain not in DOMAINS or domain in states:
            continue
        at, outcome = result.get('observed_at'), result.get('state')
        if not fresh(at, interval):
            evidence.append(domain + '：DNS 数据过期')
            continue
        old = previous.get(domain, {})
        contiguous = fresh(old.get('at'), interval) and at >= old.get('at', 0)
        current = dict(old) if contiguous else {'failures':0, 'successes':0, 'alert':False}
        if at != old.get('at') or not contiguous:
            if outcome == 'error':
                current['failures'] = current.get('failures', 0)+1
                current['successes'] = 0
                current['alert'] = current.get('alert', False) or current['failures'] >= 2
            elif outcome == 'ok':
                current['successes'] = current.get('successes', 0)+1
                current['failures'] = 0
                if current['successes'] >= 2:
                    current['alert'] = False
            else:
                current = {'failures':0, 'successes':0, 'alert':False}
        current['at'] = at
        states[domain] = current
        if current['alert']:
            alerts.append(domain)
        route = {'direct':'直连', 'proxy':'代理', 'unknown':'路由未知'}.get(result.get('route'), '路由未知')
        evidence.append(f"{domain} · {route} · {time.strftime('%H:%M:%S', time.localtime(at))} · " +
                        DNS_CODES.get(result.get('code'), 'DNS 检测不可用') +
                        ('（恢复确认中）' if current['alert'] and outcome == 'ok' else ''))
    for domain in DOMAINS:
        domain_samples = [s for s in samples if s.get('domain') == domain]
        if domain_samples:
            last = domain_samples[-1]
            detail = STAGES.get(last.get('stage'), '失败阶段未知') if not last.get('ok') else '短请求成功'
            if type(last.get('http_status')) is int:
                detail += f" HTTP {last['http_status']}"
            evidence.append(f"{domain} · {time.strftime('%H:%M:%S', time.localtime(last['at']))} · {detail}")
    tls_failed = any(len(ss := [s for s in samples if s.get('domain') == domain]) >= 3 and
                     all(s.get('stage') == 'tls' and not s.get('ok') for s in ss[-3:]) for domain in DOMAINS)
    evidence.append('Clash DNS 查询成功不保证实际请求的解析路径正常；Fake-IP 地址本身不是异常')
    return dict(alerts=alerts, tls_failed=tls_failed, state=states, evidence=evidence,
                title='连接异常，检测到 DNS 解析失败' if failures.intersection(alerts) else 'DNS 解析异常')
