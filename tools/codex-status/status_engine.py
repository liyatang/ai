"""Pure facts/diagnosis projection. History cannot make the current state red."""
from __future__ import annotations


def project(events, proxy, source, probe, previous, now, epoch_started):
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
    historical = [e for e in events if e['kind']=='retry' and now-86400 <= e['at']<=now]
    return dict(status=status,severity=severity,title=title,advice=advice,activity=activity,
                retry_count=len(retries) if valid else None,unresolved_count=len(unresolved),
                history_count=len(historical),last_retry_at=max((e['at'] for e in historical),default=None),
                active=bool(recent),can_compare=bool(valid and route_ok and (sustained or failed)),
                evidence=[source.get('error') or '近期日志事件',proxy.get('detail') or '路由未知',
                          '后台重试不代表任务重新开始','短请求探针不代表模型速度'],
                state=dict(confirmations=confirmations,confirmation_at=prior_at,
                           probe_failed=failed,epoch_started=epoch_started))


def rank_candidates(results, current, usage):
    eligible=[r for r in results if r['name']!=current and r.get('sample_count')==5
              and r.get('success_count')==5 and r.get('median_ms') is not None]
    eligible.sort(key=lambda r:(-usage.get(r['name'],0),r.get('p90_ms',10**9),r['median_ms'],r['name']))
    return eligible[0] if eligible else None
