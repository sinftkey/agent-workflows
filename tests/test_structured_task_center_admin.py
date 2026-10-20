"""Management transactions: preview isolation, approval, rollback and dead locks."""
import copy
import os
import socket
import subprocess
import sys
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch
import test_structured_task_center_extended as extended
from test_structured_task_center import ASSETS, World, args
from taskcore import install
from taskcore.codec import Fault, dumps, loads, sha
from taskcore.store import git
from taskcore.validation import Validator


class AdministrativeTests(unittest.TestCase):
    def setUp(self):
        self.w = World()

    def rejects(self, code, action):
        with self.assertRaises(Fault) as caught:
            action()
        self.assertEqual(caught.exception.code, code, str(caught.exception))

    def dead_lock(self, common):
        p = subprocess.Popen([sys.executable, '-I', '-B', '-c', 'pass'])
        p.wait(timeout=10)
        lock = common / 'task-center-write.lock'; lock.mkdir()
        token = uuid.uuid4().hex
        (lock / 'owner.json').write_bytes(dumps({'token': token, 'pid': p.pid,
            'host': socket.gethostname(), 'actor': self.w.human}))
        isolation = self.w.dir / ('isolation-' + token + '.json')
        isolation.write_bytes(dumps(self.w.source('dead-admin-isolation-' + token)))
        return token, str(isolation)

    def actor(self):
        p = self.w.dir / 'maintainer.json'; p.write_bytes(dumps(self.w.human))
        return str(p)

    def test_install_preview_failure_and_explicit_dead_lock_recovery(self):
        w = self.w
        repo = w.dir / 'another code'; repo.mkdir()
        git(repo, 'init', '-b', 'main')
        git(repo, 'config', 'user.name', 'Admin Fixture')
        git(repo, 'config', 'user.email', 'admin@example.invalid')
        (repo / 'README.md').write_bytes(b'fixture\n')
        git(repo, 'add', 'README.md'); git(repo, 'commit', '-m', 'test: isolated code')
        destination = w.dir / 'another center'
        options = args(command='install-preview', repo=str(repo), destination=str(destination),
                       policy_file=str(w.policy_file), approval_file=str(w.approval))
        head = git(repo, 'rev-parse', 'HEAD')
        plan = install.install(options)
        original_destination = options.destination
        options.destination = str(repo / 'nested-center')
        self.rejects(2, lambda: install.install(options))
        options.destination = original_destination
        self.assertFalse(destination.exists())
        self.assertEqual(git(repo, 'rev-parse', 'HEAD'), head)
        self.assertIsNone(install.subprocess_ref(repo, plan['branch']))
        options.command = 'install-apply'
        original_git = install.git
        def interrupted(root, *arguments, **kw):
            if arguments[:2] == ('worktree', 'add'):
                raise Fault(9, 'INJECTED', 'after ref, before worktree creation')
            return original_git(root, *arguments, **kw)
        self.rejects(9, lambda: self.interrupt_install(options, interrupted))
        common = install.common_dir(repo)
        self.assertTrue((common / 'task-center-v2/administration.pending').exists())
        options.actor_file = self.actor()
        preview = install.install_recover(options)
        self.assertEqual(preview['head'], preview['journal']['new_commit'])
        self.assertFalse(destination.exists())
        options.lock_token, options.isolation_file = self.dead_lock(common)
        options.apply = True
        result = install.install_recover(options)
        self.assertEqual(Path(result['destination']), destination.resolve())
        self.assertFalse(git(destination, 'status', '--porcelain').strip())
        self.assertFalse((common / 'task-center-v2/administration.pending').exists())
        self.assertEqual(git(repo, 'rev-parse', 'HEAD'), head)
        # A repeated administrative recovery may not erase the dirty-state guard.
        marker = common / 'task-center-v2/administration.pending'; marker.write_bytes(b'install\n')
        extra = destination / 'unknown-user-file'; extra.write_bytes(b'preserve\n')
        options.lock_token = None
        self.rejects(11, lambda: install.install_recover(options))
        self.assertEqual(extra.read_bytes(), b'preserve\n')
        self.assertEqual(marker.read_bytes(), b'install\n')

    def interrupt_install(self, options, function):
        with patch.object(install, 'git', side_effect=function):
            return install.install(options)

    def test_migration_pre_ref_abort_after_dead_lock(self):
        path = extended.ExtendedTests.legacy(self)
        before = git(path, 'rev-parse', 'HEAD')
        backup = self.w.dir / 'pre-ref-backup'
        options = args(command='migrate-preview', root=str(path), backup_dir=str(backup),
                       policy_file=str(self.w.policy_file), actor_file=self.actor())
        plan = install.migration_preview(options)
        plan.update(mode='approved', approval=self.w.policy['decision'], isolation_evidence=self.w.source('all-writers-isolated'))
        file = self.w.dir / 'pre-ref-plan.json'; file.write_bytes(dumps(plan)); options.plan_file = str(file)
        original_git = install.git
        def interrupted(root, *arguments, **kw):
            if arguments[0] == 'update-ref':
                raise Fault(4, 'INJECTED', 'before ref compare-and-swap')
            return original_git(root, *arguments, **kw)
        with patch.object(install, 'git', side_effect=interrupted):
            self.rejects(4, lambda: install.migration_apply(options))
        self.assertEqual(git(path, 'rev-parse', 'HEAD'), before)
        common = install.common_dir(path)
        options.lock_token, options.isolation_file = self.dead_lock(common)
        options.abort = True
        out = install.migration_recover(options)
        self.assertEqual(out['state'], 'aborted')
        self.assertFalse((common / 'task-center-v2/administration.pending').exists())
        self.assertFalse(git(path, 'status', '--porcelain').strip())
        marker = common / 'task-center-v2/administration.pending'; marker.write_bytes(b'restore\n')
        self.rejects(10, lambda: install.migration_recover(options))
        self.assertEqual(marker.read_bytes(), b'restore\n')

    def test_restore_post_ref_recovery_with_dead_lock(self):
        path = extended.ExtendedTests.legacy(self)
        options, _ = extended.ExtendedTests.migrate(self, path)
        options.actor_file = self.actor()
        plan = install.restore_preview(options)
        file = self.w.dir / 'restore-approved.json'; file.write_bytes(dumps(plan))
        options.plan_file, options.approval_file = str(file), str(self.w.approval)
        with patch.object(install, 'materialize_migration', side_effect=Fault(9, 'INJECTED', 'restore after ref')):
            self.rejects(9, lambda: install.restore_apply(options))
        common = install.common_dir(path)
        self.assertTrue((common / 'task-center-v2/administration.pending').exists())
        options.lock_token, options.isolation_file = self.dead_lock(common)
        options.apply = True
        self.assertEqual(install.restore_recover(options)['state'], 'complete')
        self.assertIn(b'tool-version: 1', git(path, 'show', 'HEAD:.task-center/version'))
        self.assertFalse(git(path, 'status', '--porcelain').strip())

    def test_tampered_plan_backup_and_runtime_do_not_advance_ref(self):
        path = extended.ExtendedTests.legacy(self)
        before = git(path, 'rev-parse', 'HEAD')
        options = args(root=str(path), backup_dir=str(self.w.dir / 'tamper-backup'), policy_file=str(self.w.policy_file))
        plan = install.migration_preview(options)
        plan.update(mode='approved', approval=self.w.policy['decision'], isolation_evidence=self.w.source('isolation'))
        file = self.w.dir / 'tamper-plan.json'; options.plan_file = str(file)
        changed = copy.deepcopy(plan); changed['policy_proposal']['body']['grants'][0]['identity'] = 'unknown-identity'
        file.write_bytes(dumps(changed))
        self.rejects(2, lambda: install.migration_apply(options))
        changed = copy.deepcopy(plan); changed['items'][0]['new_state'] = 'todo'
        file.write_bytes(dumps(changed))
        self.rejects(2, lambda: install.migration_apply(options))
        changed = copy.deepcopy(plan); changed['items'] = []
        file.write_bytes(dumps(changed))
        self.rejects(2, lambda: install.migration_apply(options))
        file.write_bytes(dumps(plan))
        backup_file = Path(options.backup_dir) / 'files' / plan['items'][0]['old_path']
        backup_file.write_bytes(b'changed original backup\n')
        self.rejects(11, lambda: install.migration_apply(options))
        with patch.dict(os.environ, {'TASK_RUNTIME_LOCK_SHA256': '0' * 64}):
            self.rejects(8, lambda: Validator(ASSETS))
        self.assertEqual(git(path, 'rev-parse', 'HEAD'), before)
        self.assertFalse(git(path, 'status', '--porcelain').strip())


if __name__ == '__main__':
    unittest.main(verbosity=2)
