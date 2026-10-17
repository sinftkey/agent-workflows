"""Integration regression tests in disposable local clones; no real migration."""
import argparse
import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ASSETS = REPO / 'templates/task-center-v2'
sys.path.insert(0, str(ASSETS / 'scripts'))
from taskcore import codec, install
from taskcore.codec import Fault, canonical, dumps, loads, sha
from taskcore.engine import Engine
from taskcore.store import Store, git
from taskcore.validation import Validator

RUNTIME = Path(os.environ['TASK_TEST_RUNTIME']).resolve()
ROOT = Path(os.environ.get('TASK_TEST_ROOT', tempfile.gettempdir())) / ('structured-' + uuid.uuid4().hex)
ROOT.mkdir(parents=True)
print('Isolated fixtures retained at:', ROOT, flush=True)
os.environ['TASK_RUNTIME_PATH'] = str(RUNTIME)
os.environ['TASK_RUNTIME_LOCK_SHA256'] = sha((RUNTIME / 'runtime-lock.json').read_bytes())
os.environ['TASK_BRANCH'] = 'task-center'
os.environ['GIT_CONFIG_NOSYSTEM'] = '1'
os.environ['GIT_CONFIG_GLOBAL'] = os.devnull
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
os.environ['TASK_PYTHON'] = sys.executable
os.environ.pop('GIT_INDEX_FILE', None)


def args(**values):
    default = dict(root=None, repo=None, destination=None, policy_file=None, runtime_dir=str(RUNTIME),
                   backup_dir=None, plan_file=None, approval_file=None, source_revision=None,
                   candidate=True, command='install-apply', apply=False, abort=False, actor_file=None,
                   lock_token=None, isolation_file=None)
    return argparse.Namespace(**dict(default, **values))


class World:
    def __init__(self, object_format='sha1'):
        self.dir = ROOT / uuid.uuid4().hex
        self.dir.mkdir()
        self.code = self.dir / 'code repo'
        self.center = self.dir / '任务 center'
        self.code.mkdir()
        self.sources = self.dir / 'evidence'
        self.sources.mkdir()
        self.serial = 0
        self.refmap = {}
        self.fixture = json.loads((REPO / 'examples/workflow-stage-c-complete.json').read_text(encoding='utf-8'))
        self.policy = self.rewrite(copy.deepcopy(self.fixture['policy']))
        write = self.policy['body']['grants'][0]['actions']
        self.policy['body']['grants'][1]['actions'] = [x for x in write if x != 'policy.update']
        self.policy['body']['grants'][2]['actions'] = [x for x in write if x not in ('task.open', 'policy.update')]
        self.policy_file = self.dir / 'policy.json'
        self.policy_file.write_bytes(dumps(self.policy))
        self.approval = self.dir / 'approval.json'
        self.approval.write_bytes(dumps(self.policy['decision']))
        git(self.code, 'init', '-b', 'main', '--object-format=' + object_format)
        git(self.code, 'config', 'user.name', 'Workflow Test')
        git(self.code, 'config', 'user.email', 'workflow@example.invalid')
        git(self.code, 'config', 'core.autocrlf', 'false')
        (self.code / 'README.md').write_text('isolated fixture\n', encoding='utf-8')
        git(self.code, 'add', 'README.md')
        git(self.code, 'commit', '-m', 'test: isolated code fixture')
        self.install_args = args(repo=str(self.code), destination=str(self.center),
                                 policy_file=str(self.policy_file), approval_file=str(self.approval))
        install.install(self.install_args)
        self.store = Store(self.center)
        self.validator = Validator(self.center)
        self.requests = self.rewrite(copy.deepcopy(self.fixture['requests']))
        self.requests[0]['actions'][0]['payload']['contract']['defaults']['policy'] = self.store.policy_ref()
        self.owner = self.requests[0]['actor']
        self.checker = self.requests[2]['actor']
        self.human = {'identity': 'human', 'run': 'run-human'}

    def source(self, label):
        if label not in self.refmap:
            self.serial += 1
            p = self.sources / (str(self.serial) + '.txt')
            p.write_text('Isolated regression evidence: ' + label + '\n', encoding='utf-8')
            self.refmap[label] = {'uri': p.as_uri(), 'sha256': sha(p.read_bytes()), 'description': 'Regression fixture only.'}
        return copy.deepcopy(self.refmap[label])

    def rewrite(self, value):
        if isinstance(value, dict):
            if 'uri' in value and 'sha256' in value:
                s = self.source(value['uri'])
                value['uri'], value['sha256'] = s['uri'], s['sha256']
            for k, v in value.items():
                value[k] = self.rewrite(v)
        elif isinstance(value, list):
            value = [self.rewrite(v) for v in value]
        return value

    def request(self, actor, actions):
        return {'kind': 'request', 'protocol': codec.PROTOCOL, 'request_id': str(uuid.uuid4()),
                'actor': copy.deepcopy(actor), 'actions': actions}

    def action(self, op, payload, expected=None, task='1'):
        return {'id': 'a-' + uuid.uuid4().hex, 'task': task, 'op': op, 'expected': expected or {}, 'payload': copy.deepcopy(payload)}

    def apply(self, request, fault=None):
        store = Store(self.center, fault=fault)
        with store.lock(request['actor'], timeout=1):
            before = store.snapshot()
            e = Engine(store, self.validator, before)
            out, receipt = e.apply(request)
            if receipt:
                out['commit'] = store.commit(before['commit'], e.changes(before, receipt), request['request_id'],
                    receipt['request_hash'], '.task-center/receipts/' + request['request_id'] + '.json', 'test: apply request')
            return out

    def normal(self, through=4):
        for request in self.requests[:through]:
            self.apply(copy.deepcopy(request))
        return Engine(self.store, self.validator)

    def query(self, op, actor=None, **kwargs):
        return Engine(self.store, self.validator).query({'kind': 'query', 'protocol': codec.PROTOCOL,
            'actor': actor or self.human, 'op': op, **kwargs})

    def policy_update(self, body):
        revision = self.store.snapshot()['policy']['revision']
        return self.request(self.human, [self.action('policy.update',
            {'replacement': body, 'decision': self.policy['decision']}, {'policy': revision}, 'policy')])


class StructuredTests(unittest.TestCase):
    def setUp(self):
        self.w = World()

    def rejected(self, code, request):
        before = self.w.store.head()
        with self.assertRaises(Fault) as caught:
            self.w.apply(request)
        self.assertEqual(caught.exception.code, code, str(caught.exception))
        self.assertEqual(self.w.store.head(), before)
        self.assertFalse(git(self.w.center, 'status', '--porcelain').strip())

    def test_normal_receipt_and_mutation(self):
        e = self.w.normal()
        self.assertEqual(e.models['1'].state, 'done')
        self.assertEqual(len(e.models['1'].doc['records']), 12)
        old = self.w.store.head()
        result = self.w.apply(copy.deepcopy(self.w.requests[3]))
        self.assertEqual(result['status'], 'replayed')
        self.assertEqual(result['gate_context'], 'historical')
        self.assertEqual(self.w.store.head(), old)
        changed = copy.deepcopy(self.w.requests[3])
        changed['actions'][-1]['expected']['delivery'] = 2
        self.rejected(5, changed)

    def test_start_before_candidate_and_blocked_assessment(self):
        prefix = copy.deepcopy(self.w.requests[0])
        prefix['actions'] = prefix['actions'][:3]
        self.w.apply(prefix)
        target = {'contract_revision': 1, 'binding': {'assignment': 'owner', 'revision': 1}}
        request = self.w.request(self.w.owner, [self.w.action('gate.evaluate',
            {'target': target, 'gate': 'start', 'advance': False}, {'contract': 1, 'assignment': 1})])
        out = self.w.apply(request)
        self.assertEqual(out['gates'][0]['outcome'], 'pass')
        self.assertFalse(out['action_results'][0]['events'])
        m = Engine(self.w.store, self.w.validator).models['1']
        self.assertEqual(m.state, 'todo')
        self.assertIsNone(m.candidate)
        block = self.w.action('block.set', {'id': 'b', 'reason': 'wait', 'gates': ['start'], 'follower': 'human',
            'waiting_for': 'fixture dependency', 'release_condition': 'explicit release', 'source': self.w.source('block')}, {'block': 0})
        self.w.apply(self.w.request(self.w.human, [block]))
        request['request_id'] = str(uuid.uuid4())
        self.assertEqual(self.w.apply(request)['gates'][0]['outcome'], 'blocked')
        begin = copy.deepcopy(self.w.requests[0]['actions'][3]); begin['task'] = '1'
        self.rejected(6, self.w.request(self.w.owner, [begin]))

    def test_atomic_batch_rejection(self):
        self.w.normal(1)
        progress = self.w.action('progress.append', {'binding': {'assignment': 'owner', 'revision': 1},
            'text': 'must not persist', 'checkpoint': None, 'sources': []})
        finish = copy.deepcopy(self.w.requests[3]['actions'][-1])
        # CAS is current, but no actual delivery/candidate exists.
        finish['expected'] = {'contract': 1, 'candidate': 0, 'delivery': 0}
        self.rejected(6, self.w.request(self.w.owner, [progress, finish]))

    def test_missing_checker_keeps_candidate_and_rejects_self_check(self):
        self.w.normal(1)
        submit = copy.deepcopy(self.w.requests[1]); submit['actions'] = submit['actions'][:2]
        self.w.apply(submit)
        e = Engine(self.w.store, self.w.validator)
        target = {'candidate': 'candidate-one', 'contract_revision': 1}
        self.assertEqual(e.models['1'].state, 'verifying')
        self.assertEqual(e.gate(e.models['1'], target, 'before-delivery', self.w.owner)['outcome'], 'blocked')
        a = copy.deepcopy(self.w.requests[1]['actions'][2]); a['payload']['identity'] = 'executor'
        self.w.apply(self.w.request(self.w.owner, [a]))
        accept = copy.deepcopy(self.w.requests[2]['actions'][0])
        self.w.apply(self.w.request(self.w.owner, [accept]))
        result = copy.deepcopy(self.w.requests[2]['actions'][1]); result['payload']['source_actor'] = self.w.owner
        self.rejected(3, self.w.request(self.w.owner, [result]))

    def test_write_revocation_read_scope_and_run_revocation(self):
        self.w.normal(1)
        body = copy.deepcopy(self.w.store.snapshot()['policy']['body'])
        body['grants'][1]['actions'] = []
        self.w.apply(self.w.policy_update(body))
        self.assertEqual(self.w.apply(copy.deepcopy(self.w.requests[0]))['status'], 'replayed')
        fresh = copy.deepcopy(self.w.requests[0]); fresh['request_id'] = str(uuid.uuid4())
        self.rejected(3, fresh)
        self.assertEqual(self.w.query('task.handoff', self.w.checker, task='1')['status'], 'read')
        with self.assertRaises(Fault) as denied:
            self.w.query('task.read', self.w.checker, task='2')
        self.assertEqual(denied.exception.code, 3)
        body = copy.deepcopy(self.w.store.snapshot()['policy']['body'])
        next(x for x in body['runs'] if x['id'] == 'run-owner')['status'] = 'revoked'
        self.w.apply(self.w.policy_update(body))
        self.rejected(3, copy.deepcopy(self.w.requests[0]))

    def test_late_result_and_candidate_cas(self):
        self.w.normal(3)
        begin = copy.deepcopy(self.w.requests[0]['actions'][3]); begin['task'] = '1'
        self.w.apply(self.w.request(self.w.owner, [begin]))
        candidate = copy.deepcopy(self.w.requests[1]['actions'][0])
        candidate['payload']['id'] = 'candidate-two'; candidate['expected']['candidate'] = 1
        self.w.apply(self.w.request(self.w.owner, [candidate]))
        candidate['payload']['id'] = 'candidate-three'
        self.rejected(4, self.w.request(self.w.owner, [candidate]))
        late = copy.deepcopy(self.w.requests[2]['actions'][1]); late['payload']['id'] = 'late-result'
        out = self.w.apply(self.w.request(self.w.checker, [late]))
        self.assertEqual(out['action_results'][0]['disposition'], 'historical')
        e = Engine(self.w.store, self.w.validator)
        self.assertEqual(e.gate(e.models['1'], {'candidate': 'candidate-two', 'contract_revision': 1},
                              'before-delivery', self.w.owner)['outcome'], 'blocked')

    def test_transaction_failure_windows(self):
        self.w.normal(1)
        class Crash(BaseException):
            pass
        for point in ['prepared', 'objects-ready', 'ref-cas-window', 'materializing', 'materialized']:
            with self.subTest(point=point):
                before = Engine(self.w.store, self.w.validator).models['1'].current()['seq']
                request = self.w.request(self.w.owner, [self.w.action('progress.append',
                    {'binding': {'assignment': 'owner', 'revision': 1}, 'text': point, 'checkpoint': None, 'sources': []})])
                def crash(name):
                    if name == point:
                        raise Crash()
                with self.assertRaises(Crash):
                    self.w.apply(request, crash)
                fresh = Store(self.w.center)
                journal = loads(fresh.pending.read_bytes())
                committed = fresh.head() == journal['new_commit']
                with fresh.lock(self.w.human, recovery=True):
                    fresh.recovery(apply=committed, abort=not committed)
                out = self.w.apply(request)
                self.assertEqual(out['status'], 'replayed' if committed else 'committed')
                self.assertEqual(Engine(fresh, self.w.validator).models['1'].current()['seq'], before + 1)

    def test_codec_and_offline_ref(self):
        for raw in [b'{"a":1,"a":2}', b'{"n":1.0}', b'{"n":-0}', b'{"x":"\\ud800"}',
                    b'\xef\xbb\xbf{}', b'{"x":"\\u0000"}', b'{"utc":"x","kind":"known"}']:
            with self.assertRaises(Fault):
                loads(raw)
        vectors = json.loads((REPO / 'design/stage-c/vectors.json').read_text(encoding='utf-8'))
        for c in vectors['canonical_cases']:
            self.assertEqual(canonical(c['value']).hex(), c['utf8_hex'])


if __name__ == '__main__':
    print('Isolated fixtures retained at:', ROOT, flush=True)
    unittest.main(verbosity=2)
