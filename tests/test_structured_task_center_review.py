"""Regressions for independently reproduced delivery, provenance and restore gaps."""
import copy
import unittest
from contextlib import contextmanager
from unittest.mock import patch

from test_structured_task_center import World
import test_structured_task_center_extended as extended
from taskcore import install
from taskcore.codec import Fault, dumps
from taskcore.engine import Engine
from taskcore.store import Store, git


class ReviewRegressions(unittest.TestCase):
    task = extended.ExtendedTests.task
    legacy = extended.ExtendedTests.legacy
    migrate = extended.ExtendedTests.migrate

    def setUp(self):
        self.w = World()
        body = copy.deepcopy(self.w.store.snapshot()['policy']['body'])
        body['grants'][2]['tasks'] = ['*']
        self.w.apply(self.w.policy_update(body))

    def rejected(self, code, function):
        with self.assertRaises(Fault) as caught:
            function()
        self.assertEqual(caught.exception.code, code, str(caught.exception))

    def historical(self, result):
        return self.w.request(self.w.human, [self.w.action('result.record-historical', {
            'result': result, 'original_assignment': self.w.source('original-assignment'),
            'verification': self.w.source('verified-original-report'), 'unverified': []})])

    def test_second_terminal_delivery_retains_late_upstream_restriction(self):
        w = self.w
        a, _ = self.task()
        b, _ = self.task({a: 'delivery-one'})
        second = copy.deepcopy(w.requests[3]['actions'][0])
        second['task'] = b
        second['payload']['id'] = 'delivery-two'
        w.apply(w.request(w.owner, [second]))
        consumers = [self.task({b: delivery}, through=0)[0]
                     for delivery in ('delivery-one', 'delivery-two')]
        issue = w.action('issue.report', {'id': 'late-upstream-issue',
            'target': {'candidate': 'candidate-one', 'contract_revision': 1},
            'results': ['independent-one'], 'deliveries': ['delivery-one'], 'impact': 'needs-review',
            'description': 'late restriction propagates to every actual delivery',
            'source': w.source('late-upstream')}, task=a)
        w.apply(w.request(w.human, [issue]))
        engine = Engine(w.store, w.validator)
        for delivery in ('delivery-one', 'delivery-two'):
            self.assertEqual(engine.models[b].deliveries[delivery]['consumes'],
                             [{'task': a, 'delivery': 'delivery-one'}])
            self.assertTrue(engine.dependency_paths(b, delivery, w.owner))
        for tid in consumers:
            target = {'contract_revision': 1, 'binding': {'assignment': 'owner', 'revision': 1}}
            self.assertNotEqual(engine.gate(engine.models[tid], target, 'start', w.owner)['outcome'], 'pass')
            begin = copy.deepcopy(w.requests[0]['actions'][-1]); begin['task'] = tid
            before = w.store.head()
            self.rejected(6, lambda: w.apply(w.request(w.owner, [begin])))
            self.assertEqual(w.store.head(), before)
        self.assertEqual(engine.models[b].state, 'done')

    def test_delivery_created_before_additional_consumption_keeps_candidate_lineage(self):
        w = self.w
        a, _ = self.task()
        second = copy.deepcopy(w.requests[3]['actions'][0]); second['task'] = a
        second['payload']['id'] = 'delivery-two'
        w.apply(w.request(w.owner, [second]))
        b, requests = self.task({a: 'delivery-one'}, through=3)
        first = copy.deepcopy(requests[3]['actions'][0])
        w.apply(w.request(w.owner, [first]))
        consume = w.action('dependency.consume', {'upstream': {'task': a, 'delivery': 'delivery-two'},
            'binding': {'assignment': 'owner', 'revision': 1}, 'purpose': 'additional confirmed input',
            'source': w.source('additional-input')}, {'contract': 1, 'assignment': 1}, b)
        w.apply(w.request(w.owner, [consume]))
        extra = copy.deepcopy(first); extra['payload']['id'] = 'delivery-two'
        w.apply(w.request(w.owner, [extra]))
        w.apply(w.request(w.owner, requests[3]['actions'][1:]))
        engine = Engine(w.store, w.validator)
        expected = [{'task': a, 'delivery': d} for d in ('delivery-one', 'delivery-two')]
        for delivery in engine.models[b].deliveries.values():
            self.assertEqual(delivery['consumes'], expected)
        # Missing binding is unknown, never a zero-input success.
        engine.models[b].deliveries['delivery-two']['consumes'] = []
        self.rejected(6, lambda: engine.dependency_paths(b, 'delivery-two', w.owner))

    def test_historical_result_cannot_retarget_original_assignment(self):
        w = self.w
        w.normal(2)
        w.apply(w.request(w.checker, [copy.deepcopy(w.requests[2]['actions'][0])]))
        candidate = copy.deepcopy(w.requests[1]['actions'][0])
        candidate['payload']['id'] = 'candidate-two'; candidate['expected']['candidate'] = 1
        candidate['payload']['authors'].append(w.checker)
        w.apply(w.request(w.owner, [candidate]))
        target = {'candidate': 'candidate-two', 'contract_revision': 1}
        own = copy.deepcopy(w.requests[1]['actions'][1]); own['payload'].update(id='self-two', target=target)
        w.apply(w.request(w.owner, [own]))
        result = copy.deepcopy(w.requests[2]['actions'][1]['payload'])
        result.update(id='forged-history', target=target, prerequisites=['self-two'])
        before = w.store.head()
        self.rejected(3, lambda: w.apply(self.historical(result)))
        self.assertEqual(w.store.head(), before)
        engine = Engine(w.store, w.validator)
        self.assertNotEqual(engine.gate(engine.models['1'], target, 'before-delivery', w.owner)['outcome'], 'pass')
        reassignment = copy.deepcopy(w.requests[1]['actions'][2])
        reassignment['payload']['target'] = target; reassignment['expected']['assignment'] = 1
        w.apply(w.request(w.owner, [reassignment]))
        accept = copy.deepcopy(w.requests[2]['actions'][0])
        accept['payload']['binding']['revision'] = 2; accept['expected']['assignment'] = 2
        w.apply(w.request(w.checker, [accept]))
        result['binding']['revision'] = 2
        self.rejected(3, lambda: w.apply(self.historical(result)))

    def test_historical_role_coverage_independence_and_revoked_valid_source(self):
        w = self.w
        w.normal(2)
        w.apply(w.request(w.checker, [copy.deepcopy(w.requests[2]['actions'][0])]))
        result = copy.deepcopy(w.requests[2]['actions'][1]['payload'])
        owner = copy.deepcopy(result)
        owner.update(id='owner-as-checker', binding={'assignment': 'owner', 'revision': 1}, source_actor=w.owner)
        self.rejected(3, lambda: w.apply(self.historical(owner)))
        # The checker was only assigned independent-one, not the author's self requirement.
        outside = copy.deepcopy(result); outside['id'] = 'outside-assigned-coverage'
        outside['coverage'] += copy.deepcopy(w.requests[1]['actions'][1]['payload']['coverage'])
        self.rejected(3, lambda: w.apply(self.historical(outside)))
        reassignment = copy.deepcopy(w.requests[1]['actions'][2]); reassignment['expected']['assignment'] = 1
        w.apply(w.request(w.owner, [reassignment]))
        body = copy.deepcopy(w.store.snapshot()['policy']['body'])
        next(x for x in body['runs'] if x['id'] == w.checker['run'])['status'] = 'revoked'
        w.apply(w.policy_update(body))
        # The source no longer has current write authority, but its original qualification is intact.
        self.rejected(3, lambda: w.apply(w.request(w.checker, [w.action('result.append', result)])))
        self.assertEqual(w.apply(self.historical(result))['status'], 'committed')
        engine = Engine(w.store, w.validator)
        self.assertEqual(engine.gate(engine.models['1'], result['target'], 'before-delivery', w.owner)['outcome'], 'pass')

    def restore_fixture(self):
        path = self.legacy()
        options, _ = self.migrate(path)
        actor = self.w.dir / 'maintainer.json'; actor.write_bytes(dumps(self.w.human))
        options.actor_file = str(actor)
        preview = install.restore_preview(options)
        fixed = self.w.dir / 'restore-approved.json'; fixed.write_bytes(dumps(preview))
        options.plan_file, options.approval_file = str(fixed), str(self.w.approval)
        return path, options

    def pending_write(self, path, phase):
        store = Store(path)
        request = self.w.request(self.w.owner, [copy.deepcopy(self.w.requests[0]['actions'][0])])
        request['actions'][0]['payload']['contract']['defaults']['policy'] = store.policy_ref()
        class Crash(BaseException):
            pass
        def crash(point):
            if point == phase:
                raise Crash()
        store.fault = crash
        with self.assertRaises(Crash), store.lock(request['actor']):
            before = store.snapshot()
            engine = Engine(store, self.w.validator, before)
            _, receipt = engine.apply(request)
            store.commit(before['commit'], engine.changes(before, receipt), request['request_id'],
                receipt['request_hash'], '.task-center/receipts/' + request['request_id'] + '.json', 'test: pending before restore')
        return store

    def assert_restore_guard(self, path, options, store):
        before = store.head()
        pending = store.pending.read_bytes()
        registration = {p: (store.runtime / p).read_bytes() for p in ('install-path', 'runtime.json')}
        self.rejected(10, lambda: install.restore_preview(options))
        self.rejected(10, lambda: install.restore_apply(options))
        self.assertEqual(store.head(), before)
        self.assertEqual(store.pending.read_bytes(), pending)
        self.assertEqual({p: (store.runtime / p).read_bytes() for p in registration}, registration)
        self.assertIn(b'tool-version: 2', git(path, 'show', 'HEAD:.task-center/version'))
        self.assertFalse((store.common / 'task-center-v2/restore-journal.json').exists())

    def test_restore_refuses_prepared_and_objects_ready_until_business_abort(self):
        for phase in ('prepared', 'objects-ready'):
            with self.subTest(phase=phase):
                self.setUp()
                path, options = self.restore_fixture()
                store = self.pending_write(path, phase)
                self.assert_restore_guard(path, options, store)
                with store.lock(self.w.human, recovery=True):
                    store.recovery(abort=True)
                self.assertFalse(store.pending.exists())
                self.assertEqual(install.restore_apply(options)['kind'], 'restore-result')

    def test_restore_rechecks_pending_after_preview_under_writer_lock(self):
        path, options = self.restore_fixture()
        original_lock = install.install_lock
        captured = []
        @contextmanager
        def interleaved(common, actor):
            captured.append(self.pending_write(path, 'objects-ready'))
            with original_lock(common, actor):
                yield
        before = git(path, 'rev-parse', 'HEAD')
        with patch.object(install, 'install_lock', interleaved):
            self.rejected(10, lambda: install.restore_apply(options))
        self.assertEqual(git(path, 'rev-parse', 'HEAD'), before)
        self.assert_restore_guard(path, options, captured[0])
        with captured[0].lock(self.w.human, recovery=True):
            captured[0].recovery(abort=True)
        committed = self.pending_write(path, 'ref-cas-window')
        with committed.lock(self.w.human, recovery=True):
            committed.recovery(apply=True)
        self.rejected(6, lambda: install.restore_preview(options))


if __name__ == '__main__':
    unittest.main(verbosity=2)
