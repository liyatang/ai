#!/usr/bin/env python3
"""Version 2 diagnostics coordinator. Input/output contain performance metadata only."""
from __future__ import annotations
import argparse
import concurrent.futures
import contextlib
import fcntl
import hashlib
import json
import math
import os
import sys
import time
from pathlib import Path
from status_logs import read_events, LOG_PATH
from status_dns import check_dns
from status_proxy import dns_environment_stamp
from status_proxy import read_proxy_snapshot, read_tun_state, resolve_gpt_proxy_context, probe_node
from status_engine import project, rank_candidates

ROOT = Path(os.path.expanduser('~/.config/quota-widget'))
STATE_PATH = ROOT/'observations-v2.json'


def load_state(path=STATE_PATH):
    try:
        state=json.loads(Path(path).read_text())
        if not isinstance(state,dict) or state.get('version')!=2:
            return {}
        if not isinstance(state.get('events',[]),list) or not isinstance(state.get('diagnosis_state',{}),dict):
            return {}
        for key in ('updated','epoch_started'):
            if key in state and (not isinstance(state[key],(int,float)) or not math.isfinite(state[key])):
                return {}
        for e in state.get('events',[]):
            if not isinstance(e,dict) or not isinstance(e.get('id'),str) or e.get('kind') not in ('retry','output','activity') or not isinstance(e.get('at'),(int,float)) or not math.isfinite(e['at']):
                return {}
        return state
    except (OSError,ValueError,AttributeError):
        return {}


def save_state(state,path=STATE_PATH):
    path=Path(path)
    temporary=path.with_name(path.name+f'.{os.getpid()}.tmp')
    try:
        fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as out:
            json.dump(state,out,ensure_ascii=False,allow_nan=False)
        os.replace(temporary,path)
        os.chmod(path,0o600)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


@contextlib.contextmanager
def state_lock(path=STATE_PATH):
    Path(path).parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd=os.open(str(path)+'.lock',os.O_CREAT|os.O_RDWR,0o600)
    deadline=time.monotonic()+.5
    try:
        while True:
            try:
                fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic()>deadline:
                    raise TimeoutError('observation lock busy')
                time.sleep(.02)
        yield
    finally:
        os.close(fd)


def collect(payload=None,log_path=LOG_PATH,path=STATE_PATH,now=None):
    payload=payload or {}
    now=time.time() if now is None else now
    config={}
    try:
        config=json.loads((ROOT/'config.json').read_text()).get('diagnostics') or {}
    except (OSError,ValueError):
        pass
    proxy,_,_=read_proxy_snapshot(configured_group=config.get('proxy_group'))
    source=read_events(log_path,now)
    tun=read_tun_state()
    with state_lock(path):
        state=load_state(path)
        prior=state.get('diagnosis_state') or {}
        identity=[payload.get('session_id','standalone'),proxy.get('environment'),proxy.get('node_id'),proxy.get('selected_name'),proxy.get('certain')]
        route_key=hashlib.sha256(json.dumps(identity).encode()).hexdigest()[:24]
        changed=state.get('route_key')!=route_key or now-state.get('updated',0)>60
        started=now if changed else state.get('epoch_started',now)
        epoch=hashlib.sha256(f'{route_key}:{started}'.encode()).hexdigest()[:24] if changed else state['epoch']
        # On first launch keep existing event times for history, never invent their route attribution.
        old_ids=set(state.get('connection_ids') or [])
        if state.get('environment') and state['environment']!=proxy.get('environment'):
            state['retired_connections']=list(old_ids)
        retired=set(state.get('retired_connections') or []) & set(proxy.get('connection_ids') or [])
        if retired:
            proxy={**proxy,'certain':False,'transitioning':True,'detail':'配置已变化，旧连接收尾'}
        events={e['id']:e for e in state.get('events',[]) if now-86400<=e.get('at',0)<=now}
        for e in source['events']:
            events[e['id']]=e
        recent_tasks={}
        for e in events.values():
            if e['kind']!='retry' and e['at']>=now-360:
                key=(e.get('task'),e['kind'])
                if e['at']>=recent_tasks.get(key,{}).get('at',0):
                    recent_tasks[key]=e
        ordered=sorted([e for e in events.values() if e['kind']=='retry']+list(recent_tasks.values()),key=lambda e:(e['at'],e['id']))
        if len(ordered)>50000:
            ordered=ordered[-50000:]
            source={**source,'state':'incomplete','error':'事件存储达到上限，历史仅为部分记录'}
        incoming_epoch=payload.get('epoch')
        samples=payload.get('samples') or []
        samples=[x for x in samples if isinstance(x,dict) and isinstance(x.get('at'),(int,float)) and isinstance(x.get('ok'),bool)]
        probe_at=max((x['at'] for x in samples),default=0)
        interval=30 if any(e['at']>=now-300 for e in ordered) else 120
        probe=dict(state='ok' if incoming_epoch==epoch and samples else 'unavailable',
                   observed_at=probe_at,interval=interval,samples=samples if incoming_epoch==epoch else [])
        dns=payload.get('dns') or {}
        if dns.get('epoch') != epoch or dns.get('environment') != dns_environment_stamp():
            dns={}
        diagnosis=project(ordered,proxy,source,probe,{} if changed else prior,now,started,dns=dns)
        benchmark=payload.get('benchmark') or {}
        if benchmark.get('epoch')==epoch and started<=benchmark.get('observed_at',0)<=now and now-benchmark.get('observed_at',0)<=600:
            candidate=benchmark.get('candidate')
            if candidate and candidate.get('name')!=proxy.get('selected_name'):
                if diagnosis['can_compare']:
                    diagnosis['advice']='可尝试：'+candidate['name']
                diagnosis['evidence'].append('本轮候选：'+candidate['name'])
                diagnosis['evidence'].append('候选短请求 5/5 成功；长连接稳定性未验证')
            elif benchmark.get('error'):
                if diagnosis['can_compare']:
                    diagnosis['advice']='暂时无法比较候选节点'
                diagnosis['evidence'].append(benchmark['error'])
        state.update(selected_name=proxy.get('selected_name'),node_id=proxy.get('node_id'),version=2,route_key=route_key,epoch=epoch,epoch_started=started,environment=proxy.get('environment'),updated=now,
                     connection_ids=proxy.get('connection_ids',[]),retired_connections=list(retired),
                     events=ordered,diagnosis_state=diagnosis.pop('state'))
        # Usage is restricted to this controller environment and monitor session.
        if changed and state.get('usage_environment')!=[payload.get('session_id'),proxy.get('environment')]:
            state['usage']={}
        if proxy.get('certain') and proxy.get('identity_confirmed') and source['state']=='ok':
            eligible={e['task'] for e in ordered if e['kind']=='output' and e.get('task') and e['at']>=started}
            retried={e['task'] for e in ordered if e['kind']=='retry' and e['at']>=started}
            state.setdefault('usage',{})[proxy['selected_name']]={'count':len(eligible-retried),'at':now}
        state['usage_environment']=[payload.get('session_id'),proxy.get('environment')]
        save_state(state,path)
    return dict(schema_version=2,observed_at=now,epoch=epoch,epoch_started=started,
                source={k:v for k,v in source.items() if k!='events'},proxy={k:v for k,v in proxy.items() if k!='connection_ids'},
                tun=tun,probe={k:v for k,v in probe.items() if k!='samples'},diagnosis=diagnosis,dns=dns)


def benchmark(payload=None):
    payload=payload or {}
    state=load_state()
    epoch=payload.get('epoch')
    base=dict(schema_version=2,epoch=epoch,observed_at=time.time(),candidate=None)
    if not epoch or state.get('epoch')!=epoch:
        return {**base,'error':'观察范围已变化，请刷新后重试'}
    proxy,proxies,connections=read_proxy_snapshot()
    context=resolve_gpt_proxy_context(proxies,connections)
    if (not context.get('available') or not proxy.get('identity_confirmed') or
        (proxy.get('environment'),proxy.get('selected_name'),proxy.get('node_id')) !=
        (state.get('environment'),state.get('selected_name'),state.get('node_id'))):
        return {**base,'error':context.get('error') or '代理环境已变化'}
    names=context['candidates']
    usage={name:item['count'] for name,item in (state.get('usage') or {}).items()
           if isinstance(item,dict) and isinstance(item.get('count'),int) and 0<=time.time()-item.get('at',0)<=86400}
    # Cover all candidates with a bounded 60s round; timed-out/incomplete candidates cannot win.
    deadline=time.monotonic()+60
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        results=list(pool.map(lambda n:probe_node(n,deadline=deadline),sorted(names,key=lambda n:(-usage.get(n,0),n))))
    after,_,_=read_proxy_snapshot()
    if (after.get('environment'),after.get('selected_name'),after.get('certain'))!=(proxy.get('environment'),proxy.get('selected_name'),True) or load_state().get('epoch')!=epoch:
        return {**base,'error':'测速期间代理已变化，结果已丢弃'}
    candidate=rank_candidates(results,context['current_name'],usage)
    return {**base,'observed_at':time.time(),'candidate':candidate,
            'error':None if candidate else '没有完成五次成功探针的候选',
            'tested_count':sum(r['sample_count']>0 for r in results),'candidate_count':len(names)}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--log-path',default=LOG_PATH)
    parser.add_argument('--probe-gpt-nodes',action='store_true')
    parser.add_argument('--check-dns',action='store_true')
    parser.add_argument('--input-json',action='store_true')
    args=parser.parse_args()
    payload=json.load(sys.stdin) if args.input_json else {}
    try:
        result=check_dns(payload) if args.check_dns else benchmark(payload) if args.probe_gpt_nodes else collect(payload,args.log_path)
        print(json.dumps(result,ensure_ascii=False,allow_nan=False))
    except (OSError,ValueError,TypeError):
        # Parent records exit category only; no raw local paths/content leave this process.
        raise SystemExit(2)


if __name__=='__main__':
    main()
