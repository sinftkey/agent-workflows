"""Clone-scoped locking, private-index commits and explicit recovery."""
import contextlib
import os
import re
import socket
import subprocess
import time
import uuid
from pathlib import Path
from .codec import Fault, atomic, dumps, loads, path_in, require, sha


def git(root, *args, data=None, env=None, fail=9):
    proc = subprocess.run(['git', '-c', 'core.quotepath=false', '-c', 'core.longpaths=true', '-C', str(root), *args],
                          input=data, capture_output=True, env=env)
    require(proc.returncode == 0, fail, 'GIT', 'Git operation failed: ' + args[0])
    return proc.stdout


class Store:
    def __init__(self, root, fault=None):
        self.root = Path(root).resolve()
        require(git(self.root, 'rev-parse', '--is-bare-repository').strip() == b'false',
                7, 'BARE', 'A local non-bare worktree is required.')
        require(Path(os.fsdecode(git(self.root, 'rev-parse', '--show-toplevel').strip())).resolve()
                == self.root, 7, 'ROOT', 'Use the task-center worktree root.')
        common = Path(os.fsdecode(git(self.root, 'rev-parse', '--git-common-dir').strip()))
        self.common = (self.root / common).resolve() if not common.is_absolute() else common.resolve()
        require(not self.root.is_symlink() and not self.common.is_symlink(), 11, 'REPARSE', 'Linked root rejected.')
        if os.name == 'nt':
            import ctypes
            require(ctypes.windll.kernel32.GetDriveTypeW(self.root.anchor) != 4,
                    7, 'NETWORK_FS', 'Network shares are not supported.')
        self.runtime = self.common / 'task-center-v2'
        self.runtime.mkdir(exist_ok=True)
        self.lock_path = self.common / 'task-center-write.lock'
        self.pending = self.runtime / 'pending.json'
        self.ref = os.fsdecode(git(self.root, 'symbolic-ref', 'HEAD').strip())
        expected = 'refs/heads/' + os.environ.get('TASK_BRANCH', 'task-center')
        require(self.ref == expected, 7, 'BRANCH', 'Task-center branch does not match TASK_BRANCH.')
        self.oid_length = len(self.head())
        self.fault = fault or (lambda _: None)
        self._blob_cache = {}
        self._policy_cache = {}
        self._policy_refs = {}
        self.version()

    def version(self):
        raw = self.blob('.task-center/version')
        require(raw is not None, 7, 'VERSION', 'Install or explicitly migrate before use.')
        lines = raw.decode('utf-8-sig').splitlines()
        fields = dict(line.split(':', 1) for line in lines if ':' in line)
        require(fields.get('tool-version', '').strip() == '2' and
                fields.get('schema-version', '').strip() == '3',
                7, 'VERSION', 'Unsupported format; old data requires explicit migration.')

    def head(self):
        return os.fsdecode(git(self.root, 'rev-parse', self.ref).strip())

    def blob(self, relative, commit=None):
        path_in(self.root, relative)
        commit = commit or self.head()
        key = (commit, relative)
        if key in self._blob_cache:
            return self._blob_cache[key]
        p = subprocess.run(['git', '-c', 'core.longpaths=true', '-C', str(self.root), 'show', commit + ':' + relative],
                           capture_output=True)
        self._blob_cache[key] = p.stdout if p.returncode == 0 else None
        return self._blob_cache[key]

    def policy_ref(self, commit=None):
        commit = commit or self.head()
        if commit in self._policy_refs:
            return dict(self._policy_refs[commit])
        blob = os.fsdecode(git(self.root, 'rev-parse', commit + ':.task-center/policy.json').strip())
        value = {'commit': commit, 'blob': blob,
                 'revision': loads(self.blob('.task-center/policy.json', commit))['revision']}
        self._policy_refs[commit] = value
        return dict(value)

    def policy_at(self, reference):
        commit = reference['commit']
        require(len(commit) == self.oid_length and re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', commit) is not None,
                2, 'POLICY_REF', 'Policy requires a full object ID.')
        actual = self.policy_ref(commit)
        require(actual == reference, 2, 'POLICY_REF', 'Pinned policy object/revision differs.')
        if commit not in self._policy_cache:
            self._policy_cache[commit] = loads(self.blob('.task-center/policy.json', commit))
        from copy import deepcopy
        return deepcopy(self._policy_cache[commit])

    def snapshot(self):
        commit = self.head()
        paths = git(self.root, 'ls-tree', '-r', '--name-only', '-z', commit).decode('utf-8').split('\0')
        assets = loads(self.blob('assets.json', commit))
        tasks, task_paths, receipts = {}, {}, {}
        lower = set()
        for p in filter(None, paths):
            require(p.casefold() not in lower, 11, 'PATH_CASE', 'Case-equivalent managed paths.')
            lower.add(p.casefold())
            path_in(self.root, p)
            allowed = p in assets or p in ('assets.json', '.task-center/policy.json', '.task-center/next-id',
                                           '.task-center/version', 'docs/tasks/INDEX.md')
            task = re.fullmatch(r'docs/tasks/(?:archive/)?([1-9][0-9]{0,14})\.json', p)
            receipt = re.fullmatch(r'\.task-center/receipts/([0-9a-f-]{36})\.json', p)
            require(allowed or task or receipt, 11, 'MANAGED_PATH', 'Unknown tracked asset: ' + p)
            if task:
                tid = task.group(1)
                require(tid not in tasks, 11, 'TASK_DUPLICATE', 'Duplicate active/archive ID.')
                tasks[tid], task_paths[tid] = loads(self.blob(p, commit)), p
            if receipt:
                receipts[receipt.group(1)] = loads(self.blob(p, commit))
        policy = loads(self.blob('.task-center/policy.json', commit))
        next_id = self.blob('.task-center/next-id', commit)
        require(next_id is not None and re.fullmatch(rb'[1-9][0-9]{0,14}\n', next_id),
                11, 'NEXT_ID', 'Invalid next-id allocator.')
        return {'commit': commit, 'policy': policy, 'tasks': tasks, 'paths': task_paths,
                'receipts': receipts, 'next_id': int(next_id)}

    @contextlib.contextmanager
    def lock(self, actor, timeout=10, recovery=False):
        token = uuid.uuid4().hex
        limit = time.monotonic() + timeout
        while True:
            try:
                self.lock_path.mkdir()
                break
            except FileExistsError:
                require(time.monotonic() < limit, 10, 'LOCK', 'Write lock held; inspect and isolate its owner.')
                time.sleep(0.025)
        owner = self.lock_path / 'owner.json'
        try:
            atomic(owner, dumps({'token': token, 'pid': os.getpid(), 'host': socket.gethostname(), 'actor': actor}))
            require(recovery or not self.pending.exists(), 10, 'RECOVERY', 'Pending transaction requires recovery.')
            require(recovery or not (self.runtime / 'administration.pending').exists(),
                    10, 'ADMIN_RECOVERY', 'Installation/migration/restore recovery is pending.')
            yield
        finally:
            if owner.exists() and loads(owner.read_bytes()).get('token') == token:
                owner.unlink()
                self.lock_path.rmdir()

    def clean(self, base):
        require(self.head() == base, 4, 'HEAD_CHANGED', 'Reload the committed snapshot.')
        status = git(self.root, 'status', '--porcelain', '--untracked-files=all')
        require(not status.strip(), 11, 'DIRTY', 'Task-center worktree/index contains uncommitted files.')
        require(not (self.common / 'task-center-runtime' / 'transactions').exists() or
                not any((self.common / 'task-center-runtime' / 'transactions').iterdir()),
                10, 'LEGACY_PENDING', 'Resolve old-tool transactions before structured writes.')

    def commit(self, base, changes, request_id, request_hash, receipt_path, message):
        self.clean(base)
        tx = self.runtime / ('tx-' + str(uuid.uuid4()))
        tx.mkdir()
        manifest = []
        for p, raw in sorted(changes.items()):
            path_in(self.root, p)
            before = self.blob(p, base)
            manifest.append({'path': p, 'before': sha(before) if before is not None else None,
                             'after': sha(raw) if raw is not None else None})
            if raw is not None:
                atomic(path_in(tx / 'after', p), raw)
            if before is not None:
                atomic(path_in(tx / 'before', p), before)
        journal = {'kind': 'journal', 'protocol': 'stage-c/2-draft', 'transaction': str(uuid.uuid4()),
                   'request_id': request_id, 'request_hash': request_hash, 'state': 'prepared',
                   'base_commit': base, 'new_commit': None, 'branch_ref': self.ref,
                   'changes': manifest, 'receipt_path': receipt_path, 'backup_uri': tx.as_uri()}
        atomic(self.pending, dumps(journal))
        self.fault('prepared')
        env = os.environ.copy()
        env['GIT_INDEX_FILE'] = str(tx / 'index')
        git(self.root, 'read-tree', base, env=env)
        for p, raw in sorted(changes.items()):
            if raw is None:
                git(self.root, 'update-index', '--force-remove', '--', p, env=env)
            else:
                oid = os.fsdecode(git(self.root, 'hash-object', '-w', '--stdin', data=raw).strip())
                git(self.root, 'update-index', '--add', '--cacheinfo', '100644', oid, p, env=env)
        tree = os.fsdecode(git(self.root, 'write-tree', env=env).strip())
        commit = os.fsdecode(git(self.root, '-c', 'commit.gpgsign=false', 'commit-tree', tree, '-p', base,
                                data=(message + '\n').encode('utf-8')).strip())
        journal.update(state='objects-ready', new_commit=commit)
        atomic(self.pending, dumps(journal))
        self.fault('objects-ready')
        git(self.root, 'update-ref', self.ref, commit, base, fail=4)
        self.fault('ref-cas-window')
        journal['state'] = 'ref-updated'
        atomic(self.pending, dumps(journal))
        self.materialize(journal, tx)
        return commit

    def materialize(self, journal, tx):
        require(self.head() == journal['new_commit'], 11, 'RECOVERY_REF', 'Unexpected current branch value.')
        current_index = os.fsdecode(git(self.root, 'write-tree').strip())
        before_tree = os.fsdecode(git(self.root, 'rev-parse', journal['base_commit'] + '^{tree}').strip())
        after_tree = os.fsdecode(git(self.root, 'rev-parse', journal['new_commit'] + '^{tree}').strip())
        require(current_index in (before_tree, after_tree), 11, 'RECOVERY_INDEX', 'User index changed; stop recovery.')
        pending = []
        for item in journal['changes']:
            p = path_in(self.root, item['path'])
            actual = sha(p.read_bytes()) if p.is_file() else None
            require(actual in (item['before'], item['after']), 11, 'RECOVERY_FILE', 'User-modified managed file; stop recovery.')
            raw = self.blob(item['path'], journal['new_commit']) if item['after'] is not None else None
            require(item['after'] is None or raw is not None and sha(raw) == item['after'],
                    11, 'RECOVERY_HASH', 'Committed file differs from journal.')
            pending.append((item, p, actual, raw))
        for item, p, actual, raw in pending:
            if item['after'] is None:
                if p.exists():
                    p.unlink()
            else:
                if actual != item['after']:
                    atomic(p, raw)
            self.fault('materializing')
        git(self.root, 'read-tree', journal['new_commit'])
        journal['state'] = 'materialized'
        atomic(self.pending, dumps(journal))
        self.fault('materialized')
        atomic(tx / 'completed.json', dumps(journal))
        self.pending.unlink()

    def recovery(self, apply=False, abort=False):
        require(self.pending.exists(), 10, 'RECOVERY', 'No pending transaction.')
        journal = loads(self.pending.read_bytes())
        from .validation import Validator
        try:
            Validator(self.root).check(journal)
        except Fault as exc:
            raise Fault(11, 'RECOVERY_JOURNAL', 'Recovery journal is invalid; preserve all files.') from exc
        require(journal['branch_ref'] == self.ref, 11, 'RECOVERY_REF', 'Journal belongs to another branch.')
        from .codec import local_uri
        tx = local_uri(journal['backup_uri']).resolve()
        require(tx.parent == self.runtime and tx.name.startswith('tx-'), 11, 'RECOVERY_PATH', 'Invalid transaction backup.')
        head = self.head()
        require(head in (journal['base_commit'], journal['new_commit']), 11, 'RECOVERY_REF', 'Unexpected ref; preserve all recovery data.')
        committed = journal['new_commit'] is not None and head == journal['new_commit']
        if apply:
            require(committed and not abort, 11, 'RECOVERY_CHOICE', 'Only materialize a confirmed commit; uncommitted transactions require abort.')
            receipt = self.blob(journal['receipt_path'], head)
            require(receipt is not None and loads(receipt)['request_hash'] == journal['request_hash'],
                    11, 'RECOVERY_RECEIPT', 'Receipt does not match the transaction.')
            self.materialize(journal, tx)
        elif abort:
            require(not committed, 11, 'RECOVERY_CHOICE', 'Do not abort a committed transaction.')
            self.clean_without_pending(journal['base_commit'])
            atomic(tx / 'aborted.json', dumps(journal))
            self.pending.unlink()
        return {'committed': committed, 'head': head, 'journal': journal}

    def clean_without_pending(self, base):
        require(self.head() == base and not git(self.root, 'status', '--porcelain').strip(),
                11, 'RECOVERY_DIRTY', 'Uncommitted source must be unchanged before abort.')
