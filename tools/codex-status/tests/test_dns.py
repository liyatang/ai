import json
import socket
import sys
import time
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagnostics
import status_dns as dns
from status_engine import project

NOW = 1800000000


def batch(at=NOW, states=None):
    states = states or {'chatgpt.com':'error'}
    return dict(state='ok', observed_at=at, interval=60, results=[
        dict(domain=d, state=s, code='upstream_timeout' if s=='error' else 'resolved',
             observed_at=at, route='direct') for d,s in states.items()])


def probe(at=NOW, stage='tls', domain='chatgpt.com'):
    return dict(state='ok', observed_at=at, interval=30,
                samples=[dict(at=at-i*30, ok=False, domain=domain, stage=stage,
                              http_status=403 if stage=='http' else None) for i in (2,1,0)])


def run(data, previous=None, at=NOW, samples=None, events=None):
    return project(events or [], {'certain':True,'identity_confirmed':True},
                   {'state':'ok','observed_at':at}, samples or {}, previous or {}, at, NOW-300, dns=data)


class DNSAdapterTests(unittest.TestCase):
    def test_fake_ip_and_real_ip_are_both_valid(self):
        for address in ('198.18.0.125', '1.2.3.4', 'fdfe:dcba:9876::1'):
            self.assertEqual(dns.classify_dns(200, {'Status':0,'Answer':[{'type':1,'data':address}]}), ('ok','resolved'))

    def test_explicit_upstream_timeout_and_rcodes(self):
        state, code = dns.classify_dns(500, {'message':'all DNS requests failed, first error: context deadline exceeded'})
        self.assertEqual((state,code), ('error','upstream_timeout'))
        for code in (2,3,5):
            self.assertEqual(dns.classify_dns(200, {'Status':code})[0], 'error')

    def test_ambiguous_or_http_failure_is_not_dns_failure(self):
        for status, body in ((401,{}),(403,{}),(500,{'message':'timeout'}),(200,{}),
                             (200,{'Status':0,'Answer':[]}),(200,{'Status':0,'Answer':[{'type':5,'data':'cname.'}]})):
            self.assertEqual(dns.classify_dns(status,body)[0], 'unavailable')

    def test_route_is_per_exact_domain_and_conflicts_are_unknown(self):
        connections = {'connections':[{'metadata':{'host':'chatgpt.com'}, 'chains':['DIRECT']},
                                      {'metadata':{'host':'api.openai.com'}, 'chains':['Japan','Proxy']}]}
        self.assertEqual(dns.domain_route('chatgpt.com',connections),'direct')
        self.assertEqual(dns.domain_route('api.openai.com',connections),'proxy')
        self.assertEqual(dns.domain_route('ws.chatgpt.com',connections),'unknown')
        connections['connections'].append({'metadata':{'host':'chatgpt.com'},'chains':['Japan','Proxy']})
        self.assertEqual(dns.domain_route('chatgpt.com',connections),'unknown')

    @patch.object(dns, '_unix_http_json', return_value={})
    @patch.object(dns, 'dns_environment_stamp', return_value='env')
    def test_bounded_parallel_queries_and_no_raw_error_storage(self, *_):
        def request(sock, path, timeout, raise_for_status):
            self.assertLessEqual(timeout,3)
            time.sleep(.04)
            return 500, json.dumps({'message':'all DNS requests failed: timeout SECRET'}).encode()
        start=time.monotonic()
        with patch.object(dns,'_unix_http_request',side_effect=request):
            result=dns.check_dns({'epoch':'E','dns_interval':60})
        self.assertLess(time.monotonic()-start,.11)
        self.assertEqual(len(result['results']),3)
        self.assertNotIn('SECRET',json.dumps(result))
        self.assertTrue(all(r['state']=='error' for r in result['results']))

    def test_controller_timeout_and_config_change(self):
        with patch.object(dns,'_unix_http_json',side_effect=socket.timeout), \
             patch.object(dns,'_unix_http_request',side_effect=socket.timeout), \
             patch.object(dns,'dns_environment_stamp',return_value='E'):
            result=dns.check_dns({'epoch':'E'})
            self.assertTrue(all(r['state']=='unavailable' for r in result['results']))
        with patch.object(dns,'_unix_http_json',return_value={}), \
             patch.object(dns,'_unix_http_request',return_value=(200,b'{"Status":0}')), \
             patch.object(dns,'dns_environment_stamp',side_effect=['A','B']):
            result=dns.check_dns({'epoch':'E'})
            self.assertEqual(result['state'],'unavailable')
            self.assertEqual(result['results'],[])


class DNSDiagnosisTests(unittest.TestCase):
    def alert(self, samples=None):
        first=run(batch())
        return run(batch(NOW+60),first['state'],NOW+60,samples=samples)

    def test_single_failure_and_repeated_reads_do_not_alert(self):
        first=run(batch())
        self.assertNotEqual(first['status'],'dns_failed')
        repeated=run(batch(),first['state'],NOW+15)
        self.assertNotEqual(repeated['status'],'dns_failed')
        self.assertEqual(self.alert()['title'],'DNS 解析异常')

    def test_original_dns_tls_case_and_no_node_recommendation(self):
        result=self.alert(samples=probe(NOW+60))
        self.assertEqual(result['title'],'连接异常，检测到 DNS 解析失败')
        self.assertEqual(result['advice'],'检查 Clash DNS 设置及上游可达性')
        self.assertFalse(result['can_compare'])
        self.assertTrue(any('直连' in e for e in result['evidence']))

    def test_other_host_and_http_rejection_do_not_prove_connection_dns_failure(self):
        for p in (probe(NOW+60,domain='api.openai.com'), probe(NOW+60,stage='http')):
            self.assertEqual(self.alert(samples=p)['title'],'DNS 解析异常')

    def test_two_successes_recover_dns_but_tls_remains(self):
        failed=self.alert()
        one=run(batch(NOW+120,{'chatgpt.com':'ok'}),failed['state'],NOW+120)
        self.assertEqual(one['status'],'dns_failed')
        two=run(batch(NOW+180,{'chatgpt.com':'ok'}),one['state'],NOW+180,samples=probe(NOW+180))
        self.assertEqual(two['status'],'tls_failed')
        self.assertFalse(two['can_compare'])

    def test_single_tls_failure_not_promoted(self):
        p=probe();p['samples']=p['samples'][-1:]
        self.assertNotEqual(run({},samples=p)['status'],'tls_failed')

    def test_stale_unavailable_and_epoch_change_clear_dns(self):
        failed=self.alert()
        self.assertNotEqual(run(batch(NOW+60),failed['state'],NOW+181)['status'],'dns_failed')
        self.assertNotEqual(run({},failed['state'],NOW+70)['status'],'dns_failed')
        previous={**failed['state'],'epoch_started':NOW-200}
        self.assertNotEqual(run(batch(NOW+120),previous,NOW+120)['status'],'dns_failed')

    def test_domains_have_independent_recovery(self):
        states={d:'error' for d in dns.DOMAINS}
        one=run(batch(states=states))
        failed=run(batch(NOW+60,states),one['state'],NOW+60)
        states['chatgpt.com']='ok'
        recovery=run(batch(NOW+120,states),failed['state'],NOW+120)
        recovered=run(batch(NOW+180,states),recovery['state'],NOW+180)
        self.assertFalse(recovered['state']['dns_state']['chatgpt.com']['alert'])
        self.assertTrue(recovered['state']['dns_state']['api.openai.com']['alert'])

    def test_independent_codex_retries_stay_red(self):
        events=[dict(id=str(i),at=NOW-10-i,kind='retry',task='a') for i in range(3)]
        one=run(batch(),events=events)
        two=run(batch(NOW+60),one['state'],NOW+60,events=events)
        self.assertEqual(two['status'],'sustained')
        self.assertEqual(two['severity'],'danger')
        self.assertIn('DNS',two['advice'])
        self.assertFalse(two['can_compare'])

    def test_old_probe_samples_stay_unknown_and_no_missing_data_fault(self):
        p=probe();p['samples']=[{'at':NOW,'ok':False}]
        result=run({},samples=p)
        self.assertNotIn(result['status'],('dns_failed','tls_failed'))
        self.assertNotIn(run({})['status'],('dns_failed','tls_failed'))

class DNSCoordinatorTests(unittest.TestCase):
    def test_repeated_collections_and_late_environment_results(self):
        route={'available':True,'certain':True,'identity_confirmed':True,'environment':'env1',
               'node_id':'node1','name':'same','selected_name':'same','connection_ids':[]}
        source={'state':'ok','observed_at':NOW,'events':[]}
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(diagnostics,'read_tun_state',return_value={'state':'enabled'}), \
             patch.object(diagnostics,'read_events',return_value=source), \
             patch.object(diagnostics,'read_proxy_snapshot',return_value=(route,{},{})), \
             patch.object(diagnostics,'dns_environment_stamp',return_value='stamp'):
            path=Path(directory)/'state.json'
            base=diagnostics.collect({'session_id':'one'},path=path,now=NOW)
            payload={'session_id':'one','epoch':base['epoch'],
                     'dns':dict(batch(),epoch=base['epoch'],environment='stamp')}
            first=diagnostics.collect(payload,path=path,now=NOW+15)
            repeated=diagnostics.collect(payload,path=path,now=NOW+30)
            self.assertNotEqual(repeated['diagnosis']['status'],'dns_failed')
            payload['dns']=dict(batch(NOW+60),epoch=base['epoch'],environment='stamp')
            alert=diagnostics.collect(payload,path=path,now=NOW+60)
            self.assertEqual(alert['diagnosis']['status'],'dns_failed')
            payload['dns']['environment']='old-stamp'
            invalid=diagnostics.collect(payload,path=path,now=NOW+75)
            self.assertEqual(invalid['dns'],{})
            self.assertNotEqual(invalid['diagnosis']['status'],'dns_failed')
            route['environment']='env2'
            payload['dns']['environment']='stamp'
            changed=diagnostics.collect(payload,path=path,now=NOW+90)
            self.assertNotEqual(changed['epoch'],base['epoch'])
            self.assertEqual(changed['dns'],{})

    def test_recovered_request_does_not_claim_current_connection_failure(self):
        one=run(batch())
        samples=probe(NOW+60)
        samples['samples'].append(dict(at=NOW+60,ok=True,domain='chatgpt.com',stage='http',http_status=200))
        result=run(batch(NOW+60),one['state'],NOW+60,samples=samples)
        self.assertEqual(result['title'],'DNS 解析异常')

    def test_three_tls_samples_with_realistic_timing_jitter(self):
        samples=probe()
        samples['samples'][0]['at']-=1
        self.assertEqual(run({},samples=samples)['status'],'tls_failed')

if __name__=='__main__':unittest.main()
