"""Process death, administrative protection and exceptional action semantics."""
import copy
import os
import socket
import subprocess
import sys
import threading
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch
import test_structured_task_center_extended as extended
from test_structured_task_center import ASSETS, REPO, RUNTIME, World, args
from taskcore import install
from taskcore.codec import Fault, dumps, loads, sha
from taskcore.engine import Engine
from taskcore.store import Store, git


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.w = World()
        body = copy.deepcopy(self.w.store.snapshot()['policy']['body'])
        body['grants'][2]['tasks'] = ['*']
        self.w.apply(self.w.policy_update(body))

    def rejects(self, code, operation):
        with self.assertRaises(Fault) as caught:
            operation()
        self.assertEqual(caught.exception.code, code, str(caught.exception))

    def test_concurrent_lock_isolation_cannot_rename_a_new_owner(self):
        from concurrent.futures import ThreadPoolExecutor
        from taskcore.cli import isolate_lock
        w = self.w
        dead = subprocess.Popen([sys.executable, '-I', '-B', '-c', 'pass']); dead.wait(timeout=10)
        token = uuid.uuid4().hex
        w.store.lock_path.mkdir()
        owner_file = w.store.lock_path / 'owner.json'
        owner_file.write_bytes(dumps({'token': token, 'pid': dead.pid, 'host': socket.gethostname(), 'actor': w.human}))
        source = w.dir / 'takeover-isolation.json'; source.write_bytes(dumps(w.source('old-writer-isolated')))
        ready, proceed = threading.Event(), threading.Event()
        actual_rename = os.rename
        new_token = uuid.uuid4().hex
        def pause_rename(before, after):
            ready.set()
            self.assertTrue(proceed.wait(5))
            actual_rename(before, after)
            w.store.lock_path.mkdir()
            owner_file.write_bytes(dumps({'token': new_token, 'pid': os.getpid(), 'host': socket.gethostname(), 'actor': w.human}))
        with patch('taskcore.cli.os.rename', side_effect=pause_rename):
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(isolate_lock, w.store.common, w.store.snapshot()['policy'], w.human, token, str(source))
                self.assertTrue(ready.wait(5))
                second = pool.submit(isolate_lock, w.store.common, w.store.snapshot()['policy'], w.human, token, str(source))
                try:
                    self.rejects(10, lambda: second.result(timeout=2))
                finally:
                    proceed.set()
                first.result(timeout=5)
        self.assertEqual(loads(owner_file.read_bytes())['token'], new_token)

    def test_hard_process_exit_lock_takeover_and_exact_retry(self):
        w = self.w
        w.normal(1)
        request = w.request(w.owner, [w.action('progress.append', {
            'binding': {'assignment': 'owner', 'revision': 1}, 'text': 'survives abrupt process exit', 'checkpoint': None, 'sources': []},
            {})])
        req = w.dir / 'crash-request.json'; req.write_bytes(dumps(request))
        script = w.dir / 'crash-writer.py'
        script.write_text('''import os,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from taskcore.codec import loads
from taskcore.store import Store
from taskcore.engine import Engine
from taskcore.validation import Validator
s=Store(sys.argv[2],fault=lambda phase: os._exit(73) if phase=="ref-cas-window" else None)
r=loads(Path(sys.argv[3]).read_bytes())
with s.lock(r["actor"]):
 b=s.snapshot(); e=Engine(s,Validator(s.root),b); out,receipt=e.apply(r)
 s.commit(b["commit"],e.changes(b,receipt),r["request_id"],receipt["request_hash"],".task-center/receipts/"+r["request_id"]+".json","test: abrupt writer")
''', encoding='utf-8')
        process = subprocess.run([sys.executable, '-I', '-B', str(script), str(w.center / 'scripts'),
                                  str(w.center), str(req)], capture_output=True, timeout=90)
        self.assertEqual(process.returncode, 73, process.stderr.decode(errors='replace'))
        store = Store(w.center)
        owner = loads((store.lock_path / 'owner.json').read_bytes())
        self.assertNotEqual(owner['pid'], os.getpid())
        self.assertTrue(store.pending.exists())
        actor = w.dir / 'maintainer.json'; actor.write_bytes(dumps(w.human))
        isolation = w.dir / 'isolation.json'; isolation.write_bytes(dumps(w.source('dead-writer-isolated')))
        out = w.dir / 'recover.json'
        command = [sys.executable, '-I', '-B', str(w.center / 'scripts/task.py'), 'recover', '--root', str(w.center),
                   '--actor-file', str(actor), '--response-file', str(out), '--apply', '--lock-token', owner['token'],
                   '--isolation-file', str(isolation)]
        recovered = subprocess.run(command, capture_output=True, timeout=90)
        self.assertEqual(recovered.returncode, 0, recovered.stderr.decode(errors='replace'))
        self.assertTrue(loads(out.read_bytes())['committed'])
        self.assertFalse(store.lock_path.exists())
        self.assertFalse(store.pending.exists())
        self.assertTrue(list(store.runtime.glob('isolated-lock-*')))
        head = store.head()
        self.assertEqual(w.apply(request)['status'], 'replayed')
        self.assertEqual(store.head(), head)
        events = Engine(store, w.validator).models['1'].doc['records']
        self.assertEqual(sum(r['request_id'] == request['request_id'] for r in events), 1)

    def test_live_lock_wrong_token_and_user_edit_are_preserved(self):
        from taskcore.cli import takeover
        w = self.w
        with w.store.lock(w.human):
            owner = loads((w.store.lock_path / 'owner.json').read_bytes())
            source = w.dir / 'isolation.json'; source.write_bytes(dumps(w.source('live-not-isolated')))
            self.rejects(10, lambda: takeover(w.store, w.human, owner['token'], str(source)))
            self.rejects(10, lambda: takeover(w.store, w.human, 'wrong', str(source)))
            self.assertTrue(w.store.lock_path.exists())
        class Stop(BaseException):
            pass
        def fail(phase):
            if phase == 'ref-cas-window':
                raise Stop()
        with self.assertRaises(Stop):
            w.apply(w.requests[0], fault=fail)
        unrelated = w.center / 'docs/tasks/INDEX.md'
        unrelated.write_bytes(b'user work must survive\n')
        self.rejects(11, lambda: w.store.recovery(apply=True))
        self.assertEqual(unrelated.read_bytes(), b'user work must survive\n')
        self.assertTrue(w.store.pending.exists())

    def test_legacy_clients_reject_new_format_including_recover(self):
        w = self.w
        before = w.store.head()
        env = dict(os.environ, TASK_CENTER_PATH=str(w.center), TASK_IDENTITY='maintainer')
        commands = [[os.environ['TASK_TEST_BASH'], str(REPO / 'templates/task-center/scripts/task.sh')]]
        if os.name == 'nt':
            commands.append([os.environ['TASK_TEST_PWSH'], '-NoProfile', '-File', str(REPO / 'templates/task-center/scripts/task.ps1')])
        for command in commands:
            for action in ['list', 'recover']:
                p = subprocess.run(command + [action], cwd=w.code, env=env, capture_output=True, timeout=30)
                self.assertNotEqual(p.returncode, 0)
                diagnostic = (p.stdout + p.stderr).decode('utf-8', errors='replace')
                self.assertTrue('版本' in diagnostic or 'version' in diagnostic.lower(), diagnostic)
        self.assertEqual(w.store.head(), before)
        self.assertFalse(git(w.center, 'status', '--porcelain').strip())

    def test_exceptional_actions_reuse_corrections_and_reconciliation(self):
        w = self.w
        w.normal(3)
        contract = copy.deepcopy(w.requests[0]['actions'][0]['payload']['contract'])
        boundary = copy.deepcopy(Engine(w.store, w.validator).models['1'].contract['boundary'])
        boundary['external'] = True
        contract['overrides'] = {'boundary': boundary}
        w.apply(w.request(w.human, [w.action('contract.revise', {'contract': contract, 'reason': 'explicit external fixture'}, {'contract': 1})]))
        candidate = copy.deepcopy(w.requests[1]['actions'][0])
        candidate['payload'].update(id='candidate-two', contract_revision=2)
        candidate['expected'] = {'contract': 2, 'assignment': 1, 'candidate': 1}
        w.apply(w.request(w.owner, [candidate]))
        target = {'candidate': 'candidate-two', 'contract_revision': 2}
        assign = copy.deepcopy(w.requests[1]['actions'][2]); assign['payload']['target'] = target
        assign['expected'] = {'assignment': 1}
        w.apply(w.request(w.owner, [assign]))
        accept = copy.deepcopy(w.requests[2]['actions'][0]); accept['payload']['binding']['revision'] = 2
        accept['expected'] = {'assignment': 2}
        w.apply(w.request(w.checker, [accept]))
        own = copy.deepcopy(w.requests[1]['actions'][1]); own['payload'].update(id='self-two', target=target)
        w.apply(w.request(w.owner, [own]))
        app = w.action('applicability.confirm', {'id': 'reuse-review', 'result': 'independent-one', 'target': target,
            'binding': {'assignment': 'check-r', 'revision': 2}, 'requirements': ['independent'], 'decision': 'reuse',
            'differences': w.source('actual-diff'), 'gaps': [], 'basis': w.source('reuse-basis')})
        # Requirement IDs come from the frozen fixture, rather than invented aliases.
        reqs = Engine(w.store, w.validator).models['1'].contract['requirements']
        independent = next(r['id'] for r in reqs if r['independence'] == 'independent')
        app['payload']['binding']['assignment'] = assign['payload']['id']
        app['payload']['requirements'] = [independent]
        w.apply(w.request(w.checker, [app]))
        e = Engine(w.store, w.validator)
        self.assertEqual(e.gate(e.models['1'], target, 'before-delivery', w.owner)['outcome'], 'pass')
        disposition = w.action('requirement.disposition', {'id': 'conditional-na', 'target': target,
            'requirement': independent, 'decision': 'not-applicable', 'reason': 'fixture condition absent',
            'basis': w.policy['decision'], 'expires': None, 'follow_up': None}, {'contract': 2, 'candidate': 2})
        w.apply(w.request(w.human, [disposition]))
        blocked = w.action('block.set', {'id': 'explicit', 'gates': ['before-delivery'], 'reason': 'fixture hold',
            'follower': 'human', 'waiting_for': 'maintainer', 'release_condition': 'explicit decision', 'source': w.source('block')}, {'block': 0})
        w.apply(w.request(w.human, [blocked]))
        w.apply(w.request(w.human, [w.action('block.resolve', {'id': 'explicit', 'basis': w.source('release-hold')}, {'block': 1})]))
        fail = copy.deepcopy(w.requests[2]['actions'][1]); fail['payload'].update(id='failed-two', target=target)
        fail['payload']['binding']['revision'] = 2
        fail['payload']['coverage'][0]['outcome'] = 'fail'
        w.apply(w.request(w.checker, [fail]))
        issue = w.action('issue.report', {'id': 'review-issue', 'target': target, 'results': ['failed-two'],
            'deliveries': [], 'impact': 'needs-review', 'description': 'failed check', 'source': w.source('issue')})
        w.apply(w.request(w.checker, [issue]))
        corrected = copy.deepcopy(fail); corrected['id'] = 'corrected-action'
        corrected['payload'].update(id='corrected-two', corrects=['failed-two'])
        corrected['payload']['coverage'][0]['outcome'] = 'pass'
        corrected['payload']['prerequisites'] = ['self-two']
        w.apply(w.request(w.checker, [corrected]))
        w.apply(w.request(w.checker, [w.action('issue.resolve', {'id': 'review-issue', 'decision': 'fixed',
            'results': ['corrected-two'], 'basis': w.source('actual-fix-review'), 'follow_up': None}, {'issue': 1})]))
        gate = copy.deepcopy(w.requests[3]['actions'][1]); gate['payload']['target'] = target
        gate['expected'] = {'contract': 2, 'candidate': 2}
        w.apply(w.request(w.owner, [gate]))
        delivery = copy.deepcopy(w.requests[3]['actions'][0]); delivery['payload'].update(target=target, boundary=boundary, observation='unknown')
        w.apply(w.request(w.owner, [delivery]))
        e = Engine(w.store, w.validator)
        self.assertEqual(e.gate(e.models['1'], target, 'retry', w.owner)['outcome'], 'blocked')
        reconcile = w.action('delivery.reconcile', {'delivery': 'delivery-one', 'actual': 'confirmed',
            'version': w.source('external-version'), 'effects': 'isolated fixture only', 'retry_safe': 'yes',
            'basis': w.policy['decision']}, {'delivery': 1})
        w.apply(w.request(w.human, [reconcile]))
        e = Engine(w.store, w.validator)
        self.assertEqual(e.gate(e.models['1'], target, 'retry', w.owner)['outcome'], 'pass')

    def test_completion_child_only_blocks_completion_and_cycle_rejected(self):
        parent, _ = extended.ExtendedTests.task(self, through=0)
        child, _ = extended.ExtendedTests.task(self, parent=parent, through=0)
        contract = copy.deepcopy(self.w.requests[0]['actions'][0]['payload']['contract'])
        contract['overrides'] = {'completion_children': [child]}
        revise = self.w.action('contract.revise', {'contract': contract, 'reason': 'required child'}, {'contract': 1}, parent)
        self.w.apply(self.w.request(self.w.human, [revise]))
        e = Engine(self.w.store, self.w.validator)
        m = e.models[parent]
        self.assertEqual(e.gate(m, {'contract_revision': 2, 'binding': {'assignment': 'owner', 'revision': 1}},
                                'start', self.w.owner)['outcome'], 'pass')
        self.rejects(6, lambda: e.dependencies(m, 'complete', self.w.owner))
        contract['overrides'] = {'dependencies': [parent]}
        cycle = self.w.action('contract.revise', {'contract': contract, 'reason': 'invalid wait on parent'}, {'contract': 1}, child)
        self.rejects(2, lambda: self.w.apply(self.w.request(self.w.human, [cycle])))

    def test_seven_reads_scope_receipts_and_no_implicit_writer(self):
        w = self.w
        w.normal()
        for op in ['policy.read', 'task.list', 'task.read', 'task.check', 'task.handoff', 'gate.read', 'receipt.read']:
            params = {} if op in ['policy.read', 'task.list'] else {'task': '1'}
            if op == 'receipt.read':
                params = {'receipt_id': w.requests[3]['request_id']}
            if op == 'gate.read':
                params['payload'] = {'target': {'candidate': 'candidate-one', 'contract_revision': 1}, 'gate': 'complete'}
            self.assertEqual(w.query(op, **params)['status'], 'read')
        body = copy.deepcopy(w.store.snapshot()['policy']['body'])
        checker = body['grants'][2]
        checker['actions'] = []
        checker['tasks'] = ['1']
        w.apply(w.policy_update(body))
        before = w.store.head()
        self.assertEqual(w.query('task.handoff', actor=w.checker, task='1')['status'], 'read')
        self.rejects(3, lambda: w.query('task.read', actor=w.checker, task='2'))
        self.rejects(3, lambda: w.query('policy.read', actor=w.checker))
        # Policy receipts need both global receipt and global policy read.
        policy_receipt = w.policy_update(body)
        w.apply(policy_receipt)
        self.rejects(3, lambda: w.query('receipt.read', actor=w.checker, receipt_id=policy_receipt['request_id']))
        body = copy.deepcopy(w.store.snapshot()['policy']['body'])
        body['grants'].pop(2)
        w.apply(w.policy_update(body))
        self.rejects(3, lambda: w.apply(copy.deepcopy(w.requests[2])))
        self.assertNotEqual(w.store.head(), before)

    def test_policy_mixed_batch_self_grant_and_default_pin(self):
        w = self.w
        w.normal(1)
        body = copy.deepcopy(w.store.snapshot()['policy']['body'])
        update = w.policy_update(body)
        update['actor'] = w.owner
        self.rejects(3, lambda: w.apply(update))
        update = w.policy_update(body)
        update['actions'].append(w.action('progress.append', {'binding': {'assignment': 'owner', 'revision': 1},
            'text': 'illegal mixed policy batch', 'checkpoint': None, 'sources': []}))
        self.rejects(2, lambda: w.apply(update))
        body['defaults'][0]['boundary']['description'] = 'new defaults for future tasks'
        w.apply(w.policy_update(body))
        engine = Engine(w.store, w.validator)
        self.assertNotEqual(engine.models['1'].contract['boundary']['description'], body['defaults'][0]['boundary']['description'])
        self.assertEqual(engine.models['1'].contract['defaults']['policy']['revision'], 1)

    def test_owner_takeover_requires_isolation_and_old_run_stays_revoked(self):
        w = self.w
        w.normal(1)
        body = copy.deepcopy(w.store.snapshot()['policy']['body'])
        next(r for r in body['runs'] if r['id'] == w.owner['run'])['status'] = 'revoked'
        body['runs'].append({'id': 'replacement-owner-run', 'identity': w.owner['identity'],
            'context': 'isolated replacement workcopy', 'status': 'active', 'basis': w.source('replacement-run')})
        w.apply(w.policy_update(body))
        assignment = copy.deepcopy(w.requests[0]['actions'][1])
        assignment['task'] = '1'; assignment['expected']['assignment'] = 1
        self.rejects(6, lambda: w.apply(w.request(w.human, [assignment])))
        assignment['payload']['isolation'] = w.source('old-owner-and-workcopy-isolated')
        w.apply(w.request(w.human, [assignment]))
        new_owner = {'identity': w.owner['identity'], 'run': 'replacement-owner-run'}
        accept = copy.deepcopy(w.requests[0]['actions'][2]); accept['task'] = '1'
        accept['expected']['assignment'] = 2; accept['payload']['binding']['revision'] = 2
        w.apply(w.request(new_owner, [accept]))
        progress = w.action('progress.append', {'binding': {'assignment': 'owner', 'revision': 2},
            'text': 'replacement continues', 'checkpoint': None, 'sources': []})
        self.rejects(3, lambda: w.apply(w.request(w.owner, [progress])))
        w.apply(w.request(new_owner, [progress]))
        model = Engine(w.store, w.validator).models['1']
        self.assertEqual(model.assignments['owner']['accepted_run'], new_owner['run'])

    def test_multitask_receipt_and_dependency_read_scope_are_atomic(self):
        w = self.w
        w.normal(1)
        second, _ = extended.ExtendedTests.task(self, through=0)
        progress = {'binding': {'assignment': 'owner', 'revision': 1}, 'text': 'two task receipt',
                    'checkpoint': None, 'sources': []}
        batch = w.request(w.owner, [w.action('progress.append', progress, task='1'),
                                     w.action('progress.append', progress, task=second)])
        w.apply(batch)
        contract = copy.deepcopy(w.requests[0]['actions'][0]['payload']['contract'])
        contract['overrides'] = {'dependencies': [second]}
        w.apply(w.request(w.human, [w.action('contract.revise', {'contract': contract, 'reason': 'explicit dependency'}, {'contract': 1})]))
        body = copy.deepcopy(w.store.snapshot()['policy']['body'])
        body['grants'][2]['actions'] = []
        body['grants'][2]['tasks'] = ['1']
        w.apply(w.policy_update(body))
        self.assertEqual(w.query('task.read', actor=w.checker, task='1')['status'], 'read')
        self.rejects(3, lambda: w.query('receipt.read', actor=w.checker, receipt_id=batch['request_id']))
        for op in ['task.check', 'task.handoff']:
            self.rejects(3, lambda: w.query(op, actor=w.checker, task='1'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
