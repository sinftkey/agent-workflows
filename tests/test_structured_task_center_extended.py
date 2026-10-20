"""End-to-end entry points, versioned corrections and administrative recovery."""
import copy
import json
import os
import subprocess
import sys
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch
from test_structured_task_center import ASSETS, REPO, ROOT, RUNTIME, World, args
from taskcore import install
from taskcore.codec import Fault, dumps, loads, sha
from taskcore.engine import Engine
from taskcore.store import Store, git


class ExtendedTests(unittest.TestCase):
    def setUp(self):
        self.w = World()
        body = copy.deepcopy(self.w.store.snapshot()['policy']['body'])
        body['grants'][2]['tasks'] = ['*']
        self.w.apply(self.w.policy_update(body))

    def task(self, dependencies=None, parent=None, through=4):
        w = self.w
        tid = str(w.store.snapshot()['next_id'])
        requests = copy.deepcopy(w.requests)
        for r in requests:
            r['request_id'] = str(uuid.uuid4())
            for a in r['actions']:
                if a['task'] != 'new':
                    a['task'] = tid
        c = requests[0]['actions'][0]['payload']['contract']
        c['defaults']['policy'] = w.store.policy_ref()
        c['overrides'] = {'dependencies': list(dependencies or {})}
        if parent:
            requests[0]['actions'][0]['payload']['parent'] = parent
        if dependencies:
            begin = requests[0]['actions'].pop()
            for upstream, delivery in dependencies.items():
                requests[0]['actions'].append(w.action('dependency.consume',
                    {'upstream': {'task': upstream, 'delivery': delivery}, 'binding': {'assignment': 'owner', 'revision': 1},
                     'purpose': 'formal regression consumption', 'source': w.source('consume-' + tid + '-' + upstream)},
                    {'contract': 1, 'assignment': 1}, 'new'))
            requests[0]['actions'].append(begin)
        if through == 0:
            requests[0]['actions'] = requests[0]['actions'][:-1]
            w.apply(requests[0])
        else:
            for r in requests[:through]:
                w.apply(r)
        return tid, requests

    def cli(self, shell, command, file=None):
        w = self.w
        output = w.dir / ('response-' + uuid.uuid4().hex + '.json')
        params = [command, '--root', str(w.center), '--response-file', str(output)]
        if file:
            params += ['--request-file' if command == 'apply' else '--query-file', str(file)]
        if shell == 'python':
            cmd = [sys.executable, '-I', '-B', str(w.center / 'scripts/task.py')]
        elif shell == 'bash':
            cmd = [os.environ.get('TASK_TEST_BASH', r'D:\Git\bin\bash.exe'), str(w.center / 'scripts/task.sh')]
        else:
            exe = os.environ['TASK_TEST_PWSH'] if shell == 'pwsh' else r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            cmd = [exe, '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(w.center / 'scripts/task.ps1')]
        p = subprocess.run(cmd + params, cwd=w.code, capture_output=True, timeout=90)
        return p, loads(output.read_bytes()) if output.exists() else None

    def test_cross_shell_normal_and_exit_codes(self):
        shells = ['bash', 'ps51', 'pwsh', 'python'] if os.name == 'nt' else ['bash', 'python', 'bash', 'python']
        for shell, request in zip(shells, self.w.requests):
            path = self.w.dir / ('request-' + shell + '.json')
            path.write_bytes(dumps(request))
            proc, out = self.cli(shell, 'apply', path)
            self.assertEqual(proc.returncode, 0, proc.stderr.decode(errors='replace'))
            self.assertEqual(out['status'], 'committed')
        for shell in shells:
            q = self.w.dir / ('query-' + shell + '.json')
            q.write_bytes(dumps({'kind': 'query', 'protocol': 'stage-c/2-draft', 'actor': self.w.human,
                                'op': 'task.read', 'task': '1'}))
            proc, out = self.cli(shell, 'query', q)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(out['data']['task']['current']['state'], 'done')
            invalid = self.w.dir / ('invalid-' + shell + '.json')
            invalid.write_bytes(b'{"kind":"request","kind":"request"}')
            proc, out = self.cli(shell, 'apply', invalid)
            self.assertEqual(proc.returncode, 2)
            self.assertFalse(out['durable'])

    def test_parallel_real_process_results(self):
        self.w.normal(2)
        body = copy.deepcopy(self.w.store.snapshot()['policy']['body'])
        body['identities'].append({'id': 'tester', 'kind': 'agent', 'status': 'active', 'basis': self.w.source('tester-id')})
        body['runs'].append({'id': 'run-tester', 'identity': 'tester', 'context': 'separate-test-process', 'status': 'active', 'basis': self.w.source('tester-run')})
        grant = copy.deepcopy(body['grants'][2]); grant.update(id='tester-grant', identity='tester')
        body['grants'].append(grant)
        self.w.apply(self.w.policy_update(body))
        assign = copy.deepcopy(self.w.requests[1]['actions'][2])
        assign['payload'].update(id='check-t', identity='tester')
        self.w.apply(self.w.request(self.w.owner, [assign]))
        accept_r = copy.deepcopy(self.w.requests[2]['actions'][0])
        self.w.apply(self.w.request(self.w.checker, [accept_r]))
        tester = {'identity': 'tester', 'run': 'run-tester'}
        accept_t = copy.deepcopy(accept_r); accept_t['payload']['binding']['assignment'] = 'check-t'
        self.w.apply(self.w.request(tester, [accept_t]))
        r = copy.deepcopy(self.w.requests[2]['actions'][1])
        t = copy.deepcopy(r); t['payload'].update(id='independent-t', source_actor=tester)
        t['payload']['binding']['assignment'] = 'check-t'
        processes = []
        for name, actor, action in [('r', self.w.checker, r), ('t', tester, t)]:
            req = self.w.dir / (name + '.json'); req.write_bytes(dumps(self.w.request(actor, [action])))
            out = self.w.dir / (name + '-out.json')
            proc = subprocess.Popen([sys.executable, '-I', '-B', str(self.w.center / 'scripts/task.py'), 'apply',
                '--root', str(self.w.center), '--request-file', str(req), '--response-file', str(out)],
                cwd=self.w.code, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            processes.append((proc, out))
        for proc, out in processes:
            _, err = proc.communicate(timeout=90)
            self.assertEqual(proc.returncode, 0, err.decode(errors='replace'))
            self.assertEqual(loads(out.read_bytes())['status'], 'committed')
        self.assertEqual(set(Engine(self.w.store, self.w.validator).models['1'].results),
                         {'self-one', 'independent-one', 'independent-t'})

    def test_takeover_historical_result_and_terminal_archive(self):
        self.w.normal(2)
        self.w.apply(self.w.request(self.w.checker, [copy.deepcopy(self.w.requests[2]['actions'][0])]))
        body = copy.deepcopy(self.w.store.snapshot()['policy']['body'])
        next(x for x in body['runs'] if x['id'] == 'run-checker')['status'] = 'revoked'
        self.w.apply(self.w.policy_update(body))
        direct = self.w.request(self.w.checker, [copy.deepcopy(self.w.requests[2]['actions'][1])])
        with self.assertRaises(Fault) as denied:
            self.w.apply(direct)
        self.assertEqual(denied.exception.code, 3)
        historical = self.w.action('result.record-historical', {'result': copy.deepcopy(self.w.requests[2]['actions'][1]['payload']),
            'original_assignment': self.w.source('original-check-binding'), 'verification': self.w.source('trusted-old-report'), 'unverified': ['timing remains unverified']})
        self.w.apply(self.w.request(self.w.human, [historical]))
        e = Engine(self.w.store, self.w.validator)
        target = {'candidate': 'candidate-one', 'contract_revision': 1}
        self.assertNotEqual(e.gate(e.models['1'], target, 'before-delivery', self.w.owner)['outcome'], 'pass')
        cancel = self.w.action('task.cancel', {'reason': 'fixture ends', 'effects': 'none', 'disposition': self.w.source('cancel'), 'follow_up': None}, {'contract': 1})
        self.w.apply(self.w.request(self.w.human, [cancel]))
        self.w.apply(self.w.request(self.w.human, [self.w.action('task.archive', {'reason': 'retain terminal facts'})]))
        self.assertTrue((self.w.center / 'docs/tasks/archive/1.json').exists())
        self.assertEqual(Engine(self.w.store, self.w.validator).models['1'].state, 'canceled')

    def test_exact_origin_two_deliveries_and_clearance(self):
        a, _ = self.task()
        second = copy.deepcopy(self.w.requests[3]['actions'][0]); second['task'] = a
        second['payload']['id'] = 'delivery-two'
        self.w.apply(self.w.request(self.w.owner, [second]))
        x, _ = self.task({a: 'delivery-one'})
        y, _ = self.task({a: 'delivery-two'})
        b, _ = self.task({x: 'delivery-one', y: 'delivery-one'})
        c, _ = self.task({b: 'delivery-one'}, through=0)
        bypass, _ = self.task({b: 'delivery-one', a: 'delivery-one'}, through=0)
        issue = self.w.action('issue.report', {'id': 'restriction-one', 'target': {'candidate': 'candidate-one', 'contract_revision': 1},
            'results': ['independent-one'], 'deliveries': ['delivery-one', 'delivery-two'], 'impact': 'needs-review',
            'description': 'same issue, two source deliveries', 'source': self.w.source('origin-report')}, task=a)
        self.w.apply(self.w.request(self.w.human, [issue]))
        target = {'contract_revision': 1, 'binding': {'assignment': 'owner', 'revision': 1}}
        engine = Engine(self.w.store, self.w.validator)
        self.assertNotEqual(engine.gate(engine.models[c], target, 'start', self.w.owner)['outcome'], 'pass')
        results = copy.deepcopy(self.w.requests[2]['actions'][1]); results['task'] = b
        results['payload']['id'] = 'revalidate-b'
        self.w.apply(self.w.request(self.w.checker, [results]))
        for revision, source_delivery in enumerate(['delivery-one', 'delivery-two'], 1):
            engine = Engine(self.w.store, self.w.validator)
            origin = {'task': a, 'kind': 'issue', 'restriction': 'restriction-one', 'delivery': source_delivery}
            witness = {'kind': 'clearance-evidence', 'local': {'task': b, 'delivery': 'delivery-one'},
                       'origin': origin, 'edges': sorted(engine.edge_signature(b, 'delivery-one')),
                       'results': ['revalidate-b'], 'report': self.w.source('actual-b-recheck-' + source_delivery)}
            path = self.w.dir / ('clearance-' + source_delivery + '.json'); path.write_bytes(dumps(witness))
            basis = {'uri': path.as_uri(), 'sha256': sha(path.read_bytes()), 'description': 'all-inputs revalidation witness'}
            payload = {'id': 'clear-' + str(revision), 'delivery': 'delivery-one', 'restriction_task': a,
                'restriction_kind': 'issue', 'restriction': 'restriction-one', 'restriction_delivery': source_delivery,
                'decision': 'excluded', 'results': ['revalidate-b'], 'basis': basis}
            if revision == 1:
                partial = copy.deepcopy(witness)
                partial['edges'] = partial['edges'][:1]
                bad = self.w.dir / 'partial-clearance.json'; bad.write_bytes(dumps(partial))
                bad_payload = copy.deepcopy(payload)
                bad_payload['basis'] = {'uri': bad.as_uri(), 'sha256': sha(bad.read_bytes()), 'description': 'partial route only'}
                before = self.w.store.head()
                with self.assertRaises(Fault) as rejected:
                    self.w.apply(self.w.request(self.w.checker, [self.w.action('dependency.clearance', bad_payload, {'delivery': 1}, b)]))
                self.assertEqual(rejected.exception.code, 6)
                self.assertEqual(self.w.store.head(), before)
            self.w.apply(self.w.request(self.w.checker, [self.w.action('dependency.clearance', payload, {'delivery': revision}, b)]))
            engine = Engine(self.w.store, self.w.validator)
            roots = engine.dependency_paths(b, 'delivery-one', self.w.owner)
            if revision == 1:
                self.assertTrue(roots)
                self.assertTrue(all(key[3] == 'delivery-two' for key, _ in roots))
            else:
                self.assertFalse(roots)
        self.assertEqual(engine.gate(engine.models[c], target, 'start', self.w.owner)['outcome'], 'pass')
        self.assertEqual(engine.models[a].state, 'done')
        self.assertEqual(engine.models[b].state, 'done')
        # This independently committed consumer had a direct A edge before the correction.
        self.assertNotEqual(engine.gate(engine.models[bypass], target, 'start', self.w.owner)['outcome'], 'pass')

    def legacy(self):
        path = self.w.dir / 'legacy center'
        path.mkdir()
        git(path, 'init', '-b', 'task-center')
        git(path, 'config', 'user.name', 'Migration Test')
        git(path, 'config', 'user.email', 'migration@example.invalid')
        git(path, 'config', 'core.autocrlf', 'false')
        source = REPO / 'templates/task-center'
        for rel in ['TASK-CENTER.md', 'scripts/task.sh', 'scripts/task.ps1', '.task-center/version']:
            dest = path / rel; dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes((source / rel).read_bytes())
        (path / '.task-center/next-id').write_bytes(b'100\n')
        (path / 'docs/tasks/archive').mkdir(parents=True)
        old = (source / 'task-file.md').read_text(encoding='utf-8-sig')
        old = old.replace('状态：待办', '状态：已完成', 1)
        (path / 'docs/tasks/archive/0001-old.md').write_text(old, encoding='utf-8')
        (path / 'docs/tasks/INDEX.md').write_text('legacy index\n', encoding='utf-8')
        git(path, 'add', '.')
        git(path, 'commit', '-m', 'test: legacy schema-2 task')
        return path

    def migrate(self, path, inject=False):
        backup = self.w.dir / ('backup-' + uuid.uuid4().hex)
        options = args(command='migrate-preview', root=str(path), backup_dir=str(backup), policy_file=str(self.w.policy_file))
        before = git(path, 'rev-parse', 'HEAD')
        plan = install.migration_preview(options)
        self.assertEqual(git(path, 'rev-parse', 'HEAD'), before)
        self.assertEqual(plan['next_id'], '100')
        plan.update(mode='approved', isolation_evidence=self.w.source('all-old-writers-isolated'), approval=self.w.policy['decision'])
        plan_file = self.w.dir / ('plan-' + uuid.uuid4().hex + '.json'); plan_file.write_bytes(dumps(plan))
        options.command = 'migrate-apply'; options.plan_file = str(plan_file)
        if inject:
            with patch.object(install, 'materialize_migration', side_effect=Fault(9, 'TEST_INTERRUPTION', 'after-ref fixture fault')):
                with self.assertRaises(Fault):
                    install.migration_apply(options)
        else:
            install.migration_apply(options)
        return options, plan

    def test_migration_and_explicit_restore(self):
        path = self.legacy()
        original = git(path, 'rev-parse', 'HEAD').decode().strip()
        options, plan = self.migrate(path)
        m = Engine(Store(path), self.w.validator).models['1']
        self.assertEqual(m.state, 'done')
        self.assertFalse(m.deliveries)
        self.assertTrue(m.legacy['missing'])
        self.assertEqual(Store(path).snapshot()['next_id'], 100)
        actor = self.w.dir / 'human.json'; actor.write_bytes(dumps(self.w.human))
        options.actor_file = str(actor)
        preview = install.restore_preview(options)
        restore_file = self.w.dir / 'restore.json'; restore_file.write_bytes(dumps(preview))
        options.plan_file = str(restore_file); options.approval_file = str(self.w.approval)
        result = install.restore_apply(options)
        self.assertEqual(result['restored_source'], original)
        self.assertEqual(git(path, 'show', 'HEAD:.task-center/version'), git(path, 'show', original + ':.task-center/version'))
        self.assertFalse(git(path, 'status', '--porcelain').strip())

    def test_migration_after_ref_recovery_and_successor_protection(self):
        path = self.legacy()
        options, _ = self.migrate(path, inject=True)
        self.assertTrue((install.common_dir(path) / 'task-center-v2/administration.pending').exists())
        actor = self.w.dir / 'maintainer.json'; actor.write_bytes(dumps(self.w.human))
        options.actor_file = str(actor); options.apply = True; options.lock_token = None
        result = install.migration_recover(options)
        self.assertEqual(result['state'], 'complete')
        self.assertFalse((install.common_dir(path) / 'task-center-v2/administration.pending').exists())
        # A successor commit is retained even if it only records an administrative note.
        (path / 'docs/tasks/INDEX.md').write_text('successor fact\n', encoding='utf-8')
        git(path, 'add', 'docs/tasks/INDEX.md'); git(path, 'commit', '-m', 'test: successor fact')
        with self.assertRaises(Fault) as blocked:
            install.restore_preview(options)
        self.assertEqual(blocked.exception.code, 6)


if __name__ == '__main__':
    print('Isolated fixtures retained at:', ROOT, flush=True)
    unittest.main(verbosity=2)
