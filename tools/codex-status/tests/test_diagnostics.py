import contextlib
import os
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import diagnostics as coordinator
import status_proxy as proxy
import status_logs as logs
from status_engine import project,rank_candidates

NOW=1800000000
TURN='01a00000-0000-7000-8000-000000000001'

def event(i,age=0,kind='retry',task='a'):
    return dict(id=str(i),at=NOW-age,kind=kind,task=task)

def projection(events,previous=None,now=NOW,route=None,source=None,probe=None,started=NOW-300):
    return project(events,route or {'certain':True,'identity_confirmed':True},source or {'state':'ok','observed_at':now},
                   probe or {},previous or {},now,started)

class EngineTests(unittest.TestCase):
    def test_screenshot_nine_historical_retries_do_not_make_current_red(self):
        events=[event(i,80000+i) for i in range(6)]+[event(i+6,700+i*30) for i in range(3)]+[event(10,20,'output')]
        result=projection(events)
        self.assertEqual(result['history_count'],9)
        self.assertEqual(result['retry_count'],0)
        self.assertEqual(result['status'],'clear')
        self.assertFalse(result['can_compare'])

    def test_recovered_events_do_not_require_switch(self):
        events=[event(i,30+i) for i in range(3)]+[event(4,10,'output')]
        result=projection(events)
        self.assertEqual(result['status'],'recovered')
        self.assertFalse(result['can_compare'])

    def test_two_distinct_collections_and_recovery(self):
        events=[event(i,20+i) for i in range(3)]
        first=projection(events)
        self.assertEqual(first['status'],'retrying')
        too_soon=projection(events,first['state'],NOW+1)
        self.assertEqual(too_soon['status'],'retrying')
        second=projection(events,first['state'],NOW+15)
        self.assertEqual(second['status'],'sustained')
        recovered=projection(events+[dict(id='o',at=NOW+16,kind='output',task='a')],second['state'],NOW+17)
        self.assertEqual(recovered['status'],'recovered')

    def test_concurrent_output_cannot_recover_other_task(self):
        events=[event(i,30+i) for i in range(3)]+[event(4,1,'output','b')]
        first=projection(events)
        self.assertEqual(projection(events,first['state'],NOW+15)['status'],'sustained')

    def test_recovered_task_cannot_supply_threshold_for_other_task(self):
        events=[event(i,30+i) for i in range(3)]+[event(4,20,'output'),event(5,5,'retry','b')]
        first=projection(events)
        self.assertEqual(projection(events,first['state'],NOW+15)['status'],'retrying')

    def test_no_output_never_implies_network_failure(self):
        self.assertEqual(projection([event(1,250,'activity')])['status'],'clear')
        self.assertEqual(projection([])['status'],'unknown')

    def test_stale_incomplete_and_unknown_route_never_recommend(self):
        events=[event(i,10+i) for i in range(3)]
        first=projection(events)
        for source in [{'state':'ok','observed_at':NOW-46},{'state':'incomplete','observed_at':NOW},{'state':'unavailable','observed_at':NOW}]:
            self.assertFalse(projection(events,first['state'],NOW+15,source=source)['can_compare'])
        self.assertFalse(projection(events,first['state'],NOW+15,route={'certain':False})['can_compare'])

    def test_probe_three_failures_two_successes_and_expiry(self):
        def p(samples,at=NOW):return dict(state='ok',observed_at=at,interval=30,samples=samples)
        samples=[dict(at=NOW-i*30,ok=False) for i in [2,1,0]]
        first=projection([],probe=p(samples))
        self.assertEqual(first['status'],'probe_failed')
        one=projection([],first['state'],NOW+30,probe=p(samples+[dict(at=NOW+30,ok=True)],NOW+30))
        self.assertEqual(one['status'],'probe_failed')
        two=projection([],one['state'],NOW+60,probe=p(samples+[dict(at=NOW+30,ok=True),dict(at=NOW+60,ok=True)],NOW+60))
        self.assertNotEqual(two['status'],'probe_failed')
        expired=projection([],first['state'],NOW+61,probe=p(samples))
        self.assertFalse(expired['can_compare'])

    def test_unknown_route_does_not_hide_confirmed_connection_failure(self):
        events=[event(i,30+i) for i in range(3)]
        first=projection(events,route={'certain':False})
        second=projection(events,first['state'],NOW+15,route={'certain':False})
        self.assertEqual(second['status'],'sustained')
        self.assertFalse(second['can_compare'])
        self.assertEqual(second['advice'],'先确认当前代理路由')

    def test_probe_failure_is_visible_even_when_logs_are_unavailable(self):
        probe=dict(state='ok',observed_at=NOW,interval=30,samples=[dict(at=NOW-i*30,ok=False) for i in [2,1,0]])
        result=projection([],source={'state':'unavailable','observed_at':NOW},probe=probe)
        self.assertEqual(result['status'],'probe_failed')
        self.assertIsNone(result['retry_count'])

    def test_epoch_change_drops_old_retry_condition(self):
        events=[event(i,30+i) for i in range(3)]
        first=projection(events)
        new=projection(events,first['state'],NOW+15,started=NOW)
        self.assertEqual(new['retry_count'],0)
        self.assertFalse(new['can_compare'])

    def test_candidate_requires_full_success_and_orders_usage_first(self):
        def r(name,good,ms): return dict(name=name,success_count=good,sample_count=5,median_ms=ms,p90_ms=ms)
        self.assertEqual(rank_candidates([r('current',5,1),r('partial',4,2),r('fast',5,5),r('observed',5,20)],'current',{'observed':2})['name'],'observed')
        self.assertIsNone(rank_candidates([r('partial',4,2)],'current',{}))

class LogTests(unittest.TestCase):
    def make_db(self,directory,rows):
        path=str(Path(directory)/'logs.sqlite')
        with contextlib.closing(sqlite3.connect(path)) as db:
            db.executescript('CREATE TABLE logs(id INTEGER PRIMARY KEY,ts INTEGER,ts_nanos INTEGER,target TEXT,level TEXT,feedback_log_body TEXT,thread_id TEXT,process_uuid TEXT); CREATE INDEX idx_logs_ts ON logs(ts DESC);')
            db.executemany('INSERT INTO logs(ts,ts_nanos,target,level,feedback_log_body,thread_id,process_uuid) VALUES (?,0,?,?,?,?,?)',rows)
            db.commit()
        return path

    def row(self,at,kind,turn=TURN):
        target={'output':logs.TARGET_OUTPUT,'retry':logs.TARGET_RETRY,'activity':logs.TARGET_CLIENT}[kind]
        detail={'output':'Output item item_type="reasoning" PRIVATE_CONTENT','retry':'stream disconnected: retrying PRIVATE_CONTENT','activity':'start PRIVATE_CONTENT'}[kind]
        return (at,target,'DEBUG',f'run_sampling_request{{turn_id={turn}}}: '+detail,'thread','process')

    def test_long_task_sql_window_and_retry_only_no_crash_or_content(self):
        with tempfile.TemporaryDirectory() as directory:
            path=self.make_db(directory,[self.row(NOW-1000,'activity'),self.row(NOW-2,'retry'),self.row(NOW-1,'output')])
            result=logs.read_events(path,NOW)
            self.assertEqual(result['state'],'ok')
            self.assertEqual(len(result['events']),2)
            self.assertNotIn('PRIVATE_CONTENT',str(result))
            self.assertEqual(projection(result['events'])['status'],'recovered')
            self.assertEqual(max(e['at'] for e in result['events']),NOW-1)

    def test_unknown_turn_keeps_retry_fact_but_cannot_infer_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            path=self.make_db(directory,[self.row(NOW-1,'retry','bad')])
            result=logs.read_events(path,NOW)
            self.assertEqual(result['state'],'incomplete')
            self.assertEqual(len(result['events']),1)
            self.assertIsNone(result['events'][0]['task'])

    def test_unknown_schema_degrades(self):
        with tempfile.TemporaryDirectory() as directory:
            path=str(Path(directory)/'empty.sqlite');sqlite3.connect(path).close()
            self.assertEqual(logs.read_events(path,NOW)['state'],'unavailable')

class ProxyTests(unittest.TestCase):
    def fixtures(self,group='Proxy'):
        return {'proxies':{'Others':{'type':'Selector','now':group,'all':[group]},group:{'type':'Selector','now':'日本','all':['日本','香港','新加坡']},'日本':{'type':'Shadowsocks','id':'jp'},'香港':{'type':'Shadowsocks','id':'hk'},'新加坡':{'type':'Shadowsocks','id':'sg'}}}, {'connections':[{'metadata':{'host':'chatgpt.com'},'chains':['日本',group,'Others']}]}
    def test_arbitrary_policy_names(self):
        for group in ['Proxy','GPT','中文组']:
            proxies,connections=self.fixtures(group)
            state=proxy.resolve_proxy_state(proxies,connections)
            self.assertTrue(state['certain'])
            self.assertEqual(state['selector'],group)
            self.assertEqual(proxy.resolve_gpt_proxy_context(proxies,connections)['candidates'],['日本','新加坡'])
    def test_domain_boundary_and_absent_connections(self):
        p,c=self.fixtures();c['connections'][0]['metadata']['host']='fakechatgpt.com'
        self.assertFalse(proxy.resolve_proxy_state(p,c)['certain'])
        self.assertFalse(proxy.resolve_proxy_state(p,{})['certain'])
    def test_multiroute_and_old_connection(self):
        p,c=self.fixtures();c['connections'].append({'metadata':{'host':'api.openai.com'},'chains':['新加坡','Proxy']})
        self.assertFalse(proxy.resolve_proxy_state(p,c)['certain'])
        p,c=self.fixtures();p['proxies']['Proxy']['now']='新加坡'
        state=proxy.resolve_proxy_state(p,c)
        self.assertTrue(state['transitioning']);self.assertFalse(state['certain'])
    def test_tun_and_chunked_transport(self):
        self.assertEqual(proxy.evaluate_tun({'tun':{'enable':False}},'','')['state'],'disabled')
        self.assertEqual(proxy._decode_chunked(b'4\r\ntest\r\n0\r\n\r\n'),b'test')

class CoordinatorTests(unittest.TestCase):
    def test_repeated_poll_deduplicates_and_epoch_resets_same_name(self):
        route={'available':True,'certain':True,'environment':'env1','node_id':'node1','name':'same','selected_name':'same','connection_ids':[]}
        source={'state':'ok','observed_at':NOW,'events':[event(1,0,'retry')]}
        with tempfile.TemporaryDirectory() as directory,patch.object(coordinator,'read_tun_state',return_value={'state':'enabled'}),patch.object(coordinator,'read_events',return_value=source),patch.object(coordinator,'read_proxy_snapshot',return_value=(route,{},{})):
            path=Path(directory)/'state.json'
            first=coordinator.collect({'session_id':'one'},path=path,now=NOW)
            second=coordinator.collect({'session_id':'one'},path=path,now=NOW+15)
            self.assertEqual(second['diagnosis']['history_count'],1)
            self.assertEqual(first['epoch'],second['epoch'])
            route['node_id']='newnode'
            third=coordinator.collect({'session_id':'one'},path=path,now=NOW+30)
            self.assertNotEqual(third['epoch'],first['epoch'])
            self.assertEqual(third['diagnosis']['retry_count'],0)
            fourth=coordinator.collect({'session_id':'one'},path=path,now=NOW+100)
            self.assertNotEqual(fourth['epoch'],third['epoch'])
            self.assertEqual(os.stat(path).st_mode&0o777,0o600)

class BenchmarkBoundaryTests(unittest.TestCase):
    def test_live_node_changed_before_benchmark_is_rejected(self):
        route={'available':True,'certain':True,'identity_confirmed':True,'environment':'env','selected_name':'B','node_id':'idB'}
        old={'epoch':'A-epoch','environment':'env','selected_name':'A','node_id':'idA'}
        context={'available':True,'candidates':['A','B'],'current_name':'B'}
        with patch.object(coordinator,'load_state',return_value=old),patch.object(coordinator,'read_proxy_snapshot',return_value=(route,{},{})),patch.object(coordinator,'resolve_gpt_proxy_context',return_value=context),patch.object(coordinator,'probe_node') as probe:
            result=coordinator.benchmark({'epoch':'A-epoch'})
            self.assertIsNone(result['candidate'])
            probe.assert_not_called()

    def test_environment_changes_during_benchmark_drop_result(self):
        route={'available':True,'certain':True,'identity_confirmed':True,'environment':'env','selected_name':'A','node_id':'idA'}
        old={'epoch':'epoch','environment':'env','selected_name':'A','node_id':'idA'}
        context={'available':True,'candidates':['B'],'current_name':'A'}
        candidate=dict(name='B',sample_count=5,success_count=5,median_ms=10,p90_ms=20)
        after={**route,'environment':'new'}
        with patch.object(coordinator,'load_state',return_value=old),patch.object(coordinator,'read_proxy_snapshot',side_effect=[(route,{},{}),(after,{},{})]),patch.object(coordinator,'resolve_gpt_proxy_context',return_value=context),patch.object(coordinator,'probe_node',return_value=candidate):
            result=coordinator.benchmark({'epoch':'epoch'})
            self.assertIsNone(result['candidate'])
            self.assertIn('丢弃',result['error'])

    def test_missing_node_id_disables_node_advice(self):
        events=[event(i,30+i) for i in range(3)]
        result=projection(events,route={'certain':True,'identity_confirmed':False})
        self.assertFalse(projection(events,result['state'],NOW+15,route={'certain':True,'identity_confirmed':False})['can_compare'])

    def test_corrupt_cache_recovers_without_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'state.json'
            path.write_text('{"version":2,"events":"wrong"}')
            self.assertEqual(coordinator.load_state(path),{})

if __name__=='__main__':unittest.main()
