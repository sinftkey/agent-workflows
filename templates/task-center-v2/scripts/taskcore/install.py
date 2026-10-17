"""Explicit, local install/migration plans. Never imports process role lists."""
import contextlib
import os
import re
import socket
import uuid
from pathlib import Path
from . import auth
from .codec import Fault, atomic, dumps, evidence, loads, now, path_in, require, sha
from .store import Store, git
from .validation import Validator


def common_dir(repo):
    require(git(repo, 'rev-parse', '--is-bare-repository').strip() == b'false',
            7, 'BARE', 'Use a local non-bare worktree.')
    require(Path(os.fsdecode(git(repo, 'rev-parse', '--show-toplevel').strip())).resolve() == Path(repo).resolve(),
            7, 'ROOT', 'Use the exact worktree root.')
    path = Path(os.fsdecode(git(repo, 'rev-parse', '--git-common-dir').strip()))
    return (Path(repo) / path).resolve() if not path.is_absolute() else path.resolve()


def administration_guard(common, operation=None):
    marker = common / 'task-center-v2/administration.pending'
    if marker.exists():
        require(operation is not None and marker.read_bytes() == (operation + '\n').encode(),
                10, 'ADMIN_RECOVERY', 'Use the recovery entry for the actual pending administration operation.')


def restore_pending_guard(common):
    administration_guard(common)
    require(not (common / 'task-center-v2/pending.json').exists(),
            10, 'PENDING', 'Recover or abort the pending structured transaction before restoring the old format.')


@contextlib.contextmanager
def install_lock(common, actor):
    lock = common / 'task-center-write.lock'
    try:
        lock.mkdir()
    except FileExistsError as exc:
        raise Fault(10, 'LOCK', 'A writer/recovery lock is present; do not install concurrently.') from exc
    token = uuid.uuid4().hex
    owner = lock / 'owner.json'
    try:
        atomic(owner, dumps({'token': token, 'pid': os.getpid(), 'host': socket.gethostname(), 'actor': actor}))
        yield
    finally:
        if owner.exists() and loads(owner.read_bytes()).get('token') == token:
            owner.unlink()
            lock.rmdir()


def asset_root():
    return Path(__file__).resolve().parents[2]


def assets():
    root = asset_root()
    manifest = loads((root / 'assets.json').read_bytes())
    files = {'assets.json': (root / 'assets.json').read_bytes()}
    for rel, digest in manifest.items():
        p = path_in(root, rel)
        raw = p.read_bytes()
        require(sha(raw) == digest, 8, 'ASSET_HASH', 'Source asset differs from its manifest.')
        files[rel] = raw
    return files


def runtime(args):
    require(args.runtime_dir, 8, 'RUNTIME', 'Select the prepared offline runtime.')
    path = Path(args.runtime_dir).resolve()
    lock_path = path / 'runtime-lock.json'
    require(lock_path.is_file(), 8, 'RUNTIME_LOCK', 'Prepare a hashed offline runtime first.')
    lock = loads(lock_path.read_bytes())
    require(args.candidate or lock.get('release_approved') is True,
            8, 'RELEASE_BLOCKED', 'Runtime release audit is not complete; only explicit isolated candidate use is allowed.')
    for rel, digest in lock['files'].items():
        require(sha(path_in(path, rel).read_bytes()) == digest, 8, 'RUNTIME_HASH', 'Runtime file differs from the offline lock.')
    os.environ['TASK_RUNTIME_PATH'] = str(path)
    os.environ['TASK_RUNTIME_LOCK_SHA256'] = sha(lock_path.read_bytes())
    Validator(asset_root())
    return {'path': str(path), 'lock_sha256': sha(lock_path.read_bytes()),
            'candidate': not lock.get('release_approved', False)}


def approved_policy(args):
    require(args.policy_file, 3, 'BOOTSTRAP', 'An explicitly approved policy file is required.')
    validator = Validator(asset_root())
    policy = validator.check(loads(Path(args.policy_file).read_bytes()))
    return bootstrap_policy(policy)


def bootstrap_policy(policy):
    """Apply the same semantic bootstrap checks to fresh installs and fixed plans."""
    require(policy['kind'] == 'policy' and policy['revision'] == 1, 2, 'BOOTSTRAP', 'Initial policy revision must be 1.')
    auth.policy_check(policy)
    evidence(policy['decision']['source'])
    identity = policy['decision']['identity']
    require(any(g['identity'] == identity and 'policy.update' in g['actions'] and '*' in g['tasks']
                for g in policy['body']['grants']), 3, 'BOOTSTRAP', 'Explicit policy maintainer delegation required.')
    return policy


def approval(args, policy):
    require(args.approval_file, 3, 'APPROVAL', 'Apply requires a fixed explicit approval source.')
    confirm = loads(Path(args.approval_file).read_bytes())
    check = dict(policy, decision=confirm)
    Validator(asset_root()).check(check)
    require(confirm['identity'] == policy['decision']['identity'], 3, 'APPROVAL', 'Approval identity differs from the maintainer decision.')
    evidence(confirm['source'])
    return confirm


def outside(repo, common, directory):
    path = Path(directory).resolve()
    require(not path.is_relative_to(repo) and not path.is_relative_to(common) and path not in (repo, common),
            2, 'BACKUP_LOCATION', 'Backup must be outside the source clone and common Git directory.')
    return path


def create_commit(repo, files, parent=None, message='docs(tasks): bootstrap structured task center'):
    common = common_dir(repo)
    git(repo, 'rev-parse', '--verify', 'HEAD', fail=7)
    temp = common / 'task-center-v2' / ('build-' + uuid.uuid4().hex)
    temp.mkdir(parents=True)
    env = os.environ.copy()
    env['GIT_INDEX_FILE'] = str(temp / 'index')
    git(repo, 'read-tree', parent or '--empty', env=env)
    if parent:
        previous = git(repo, 'ls-tree', '-r', '--name-only', parent).decode().splitlines()
        for p in previous:
            git(repo, 'update-index', '--force-remove', '--', p, env=env)
    for p, raw in files.items():
        path_in(temp, p)
        oid = os.fsdecode(git(repo, 'hash-object', '-w', '--stdin', data=raw).strip())
        git(repo, 'update-index', '--add', '--cacheinfo', '100644', oid, p, env=env)
    tree = os.fsdecode(git(repo, 'write-tree', env=env).strip())
    args = ['-c', 'commit.gpgsign=false', 'commit-tree', tree]
    if parent:
        args += ['-p', parent]
    return os.fsdecode(git(repo, *args, data=(message + '\n').encode()).strip())


def version_bytes(revision):
    return ('tool-version: 2\nschema-version: 3\nsource-revision: ' + revision + '\n').encode()


def install(args):
    repo = Path(args.repo or Path.cwd()).resolve()
    common = common_dir(repo)
    settings = runtime(args)
    policy = approved_policy(args)
    destination = Path(args.destination or (repo.parent / (repo.name + '-tasks'))).resolve()
    require(destination != repo and not destination.is_relative_to(repo) and not repo.is_relative_to(destination) and
            not destination.is_relative_to(common), 2, 'DESTINATION', 'Choose an empty destination outside the source clone/common Git directory.')
    require(not destination.exists() or (destination.is_dir() and not any(destination.iterdir())),
            11, 'DESTINATION', 'Fresh install requires an empty/unoccupied destination.')
    branch = 'refs/heads/' + os.environ.get('TASK_BRANCH', 'task-center')
    existing = subprocess_ref(repo, branch)
    require(existing is None, 7, 'MIGRATION_REQUIRED', 'Target branch exists; use explicit migration, not overwrite.')
    files = assets()
    revision = args.source_revision or os.fsdecode(git(asset_root(), 'rev-parse', 'HEAD').strip())
    files.update({'.task-center/version': version_bytes(revision), '.task-center/policy.json': dumps(policy),
                  '.task-center/next-id': b'1\n', 'docs/tasks/INDEX.md': b'# Task index\n\nNo tasks.\n'})
    plan = {'kind': 'install-plan', 'branch': branch, 'repo': str(repo), 'destination': str(destination),
            'source_revision': revision, 'files': {p: sha(raw) for p, raw in sorted(files.items())},
            'runtime': settings, 'policy_decision': policy['decision'], 'candidate': args.candidate}
    if args.command == 'install-preview':
        return plan
    confirm = approval(args, policy)
    with install_lock(common, {'identity': confirm['identity'], 'run': 'bootstrap'}):
        require(not (common / 'task-center-v2/administration.pending').exists(), 10, 'ADMIN_RECOVERY', 'Recover the previous administration operation first.')
        require(subprocess_ref(repo, branch) is None, 4, 'INSTALL_RACE', 'Branch appeared after preview.')
        require(not (common / 'task-center-v2/pending.json').exists(), 10, 'PENDING', 'Pending structured transaction.')
        old = common / 'task-center-runtime/transactions'
        require(not old.exists() or not any(old.iterdir()), 10, 'LEGACY_PENDING', 'Resolve old pending transactions first.')
        commit = create_commit(repo, files)
        journal = {'plan': plan, 'new_commit': commit, 'state': 'objects-ready', 'approval': confirm}
        journal_file = common / 'task-center-v2/install-journal.json'
        atomic(journal_file, dumps(journal))
        atomic(common / 'task-center-v2/administration.pending', b'install\n')
        git(repo, 'update-ref', branch, commit, '0' * len(commit), fail=4)
        journal['state'] = 'ref-updated'
        atomic(journal_file, dumps(journal))
        git(repo, 'worktree', 'add', str(destination), branch.removeprefix('refs/heads/'))
        for p, digest in plan['files'].items():
            # Git may materialize platform line endings; explicitly restore approved bytes.
            if sha(path_in(destination, p).read_bytes()) != digest:
                atomic(path_in(destination, p), files[p])
        runtime_dir = common / 'task-center-v2'
        atomic(runtime_dir / 'runtime.json', dumps(settings))
        atomic(runtime_dir / 'install-path', (str(destination) + '\n').encode())
        journal['state'] = 'complete'
        atomic(journal_file, dumps(journal))
        require(not git(destination, 'status', '--porcelain', '--untracked-files=all').strip(), 11, 'INSTALL_DIRTY', 'Installed tree differs from the approved commit.')
        (common / 'task-center-v2/administration.pending').unlink()
        return {'kind': 'install-result', 'commit': commit, 'destination': str(destination), 'candidate': args.candidate}


def subprocess_ref(repo, branch):
    import subprocess
    p = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--verify', branch], capture_output=True)
    return os.fsdecode(p.stdout.strip()) if p.returncode == 0 else None


def migration_preview(args):
    repo = Path(args.root or args.repo or Path.cwd()).resolve()
    common = common_dir(repo)
    administration_guard(common)
    for pending in [common / 'task-center-runtime/transactions', common / 'task-center-v2/pending.json', common / 'task-center-write.lock']:
        require(not pending.exists() or pending.is_dir() and not any(pending.iterdir()),
                10, 'PENDING', 'Resolve/isolate old or structured writer transactions before creating the migration backup.')
    runtime(args)
    policy = approved_policy(args)
    require(args.backup_dir, 2, 'BACKUP', 'Specify a clone-external backup directory.')
    backup = outside(repo, common, args.backup_dir)
    require(not backup.exists() or not any(backup.iterdir()), 11, 'BACKUP', 'Use a new empty backup location.')
    require(not git(repo, 'status', '--porcelain', '--untracked-files=all').strip(), 11, 'DIRTY', 'Source task worktree must be clean before backup.')
    source = os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip())
    require(os.fsdecode(git(repo, 'symbolic-ref', 'HEAD').strip()) == 'refs/heads/' + os.environ.get('TASK_BRANCH', 'task-center'),
            7, 'BRANCH', 'Migration must target the task-center branch, not the code branch.')
    raw_version = git(repo, 'show', source + ':.task-center/version').decode('utf-8-sig')
    require(re.search(r'^tool-version:\s*1\s*$', raw_version, re.M) and
            re.search(r'^schema-version:\s*2\s*$', raw_version, re.M), 7, 'VERSION', 'Only tool 1/schema 2 has this migration.')
    names = git(repo, 'ls-tree', '-r', '--name-only', source).decode().splitlines()
    backup.mkdir(parents=True, exist_ok=True)
    original = {}
    items, numbers, issues = [], set(), []
    mapping = {'待办': 'todo', '已认领': 'todo', '进行中': 'active', '待审核': 'verifying',
               '待测试': 'verifying', '待合并': 'verifying', '已完成': 'done', '已取消': 'canceled'}
    for name in names:
        require(name in {'TASK-CENTER.md', 'scripts/task.sh', 'scripts/task.ps1', '.task-center/version',
                         '.task-center/next-id', 'docs/tasks/INDEX.md'} or
                re.fullmatch(r'docs/tasks/(?:archive/)?[0-9]+-[a-z0-9][a-z0-9-]*\.md', name),
                2, 'LEGACY_ASSET', 'Unknown legacy asset; preserve it and resolve the migration plan manually.')
        raw = git(repo, 'show', source + ':' + name)
        atomic(path_in(backup / 'files', name), raw)
        original[name] = sha(raw)
        if name.startswith('docs/tasks/') and name != 'docs/tasks/INDEX.md' and name.endswith('.md'):
            match = re.fullmatch(r'docs/tasks/(?:archive/)?([0-9]+)-[a-z0-9][a-z0-9-]*\.md', name)
            require(match is not None, 2, 'LEGACY_PATH', 'Unknown legacy task filename.')
            tid = str(int(match.group(1)))
            require(tid != '0' and len(tid) <= 15 and tid not in numbers, 2, 'ID_COLLISION', 'Legacy equivalent task numbers collide.')
            numbers.add(tid)
            text = raw.decode('utf-8-sig')
            status = re.search(r'^状态：([^\r\n]+)', text, re.M)
            require(status is not None, 2, 'LEGACY_STATE', 'Original task state is missing.')
            state = status.group(1).strip()
            effective = state
            if state == '阻塞':
                prior = re.search(r'^阻塞前状态：([^\r\n]+)', text, re.M)
                effective = prior.group(1).strip() if prior else ''
            target_state = mapping.get(effective)
            if target_state is None:
                issues.append(gap_value('STATE_UNKNOWN', tid, 'Original blocked/prior state cannot be derived.'))
            item = {'old_path': name, 'old_hash': sha(raw), 'task_id': tid,
                    'new_path': 'docs/tasks/' + ('archive/' if target_state in ('done', 'canceled') else '') + tid + '.json',
                    'new_hash': None, 'old_state': state, 'new_state': target_state,
                    'missing': ['Modern contract, authorization, checks and delivery facts require explicit verification.']}
            items.append(item)
    bundle = backup / 'source.bundle'
    git(repo, 'bundle', 'create', str(bundle), '--all')
    git(repo, 'bundle', 'verify', str(bundle))
    manifest = {'source_commit': source, 'files': original, 'bundle_sha256': sha(bundle.read_bytes()),
                'common_dir': str(common), 'old_registration': []}
    for path in ['task-center/install-path', 'task-center-runtime/registration']:
        file = common / path
        if file.is_file():
            raw = file.read_bytes()
            atomic(path_in(backup / 'common', path), raw)
            manifest['old_registration'].append({'path': path, 'sha256': sha(raw)})
    manifest_file = backup / 'backup-manifest.json'
    atomic(manifest_file, dumps(manifest))
    manifest_ref = {'uri': manifest_file.as_uri(), 'sha256': sha(manifest_file.read_bytes()), 'description': 'Verified clone-external original assets and Git bundle.'}
    old_next = git(repo, 'show', source + ':.task-center/next-id').decode().strip()
    require(old_next.isdecimal() and 1 <= int(old_next) <= 999999999999999, 2, 'NEXT_ID', 'Original allocator is invalid.')
    plan = {'kind': 'migration-plan', 'protocol': 'stage-c/2-draft', 'plan_id': str(uuid.uuid4()), 'mode': 'preview',
            'source_commit': source, 'source_tool': 1, 'source_schema': 2, 'target_tool': 2, 'target_schema': 3,
            'source_revision': args.source_revision or os.fsdecode(git(asset_root(), 'rev-parse', 'HEAD').strip()), 'backup_uri': backup.as_uri(),
            'backup_manifest': manifest_ref, 'isolation_evidence': None, 'policy_proposal': policy,
            'items': items, 'next_id': str(max(int(old_next), max(map(int, numbers), default=0) + 1)), 'issues': issues, 'approval': None}
    for item in items:
        if item['new_state'] is not None:
            item['new_hash'] = sha(dumps(legacy_document(item, backup)))
    Validator(asset_root()).check(plan)
    return plan


def gap_value(code, task, message):
    return {'code': code, 'task': task, 'object': None, 'message': message}


def legacy_document(item, backup):
    raw = path_in(backup / 'files', item['old_path']).read_bytes()
    require(sha(raw) == item['old_hash'], 11, 'BACKUP_CHANGED', 'Original task backup differs.')
    text = raw.decode('utf-8-sig')
    title = text.splitlines()[0].lstrip('# ').strip() or 'Imported task'
    owner = re.search(r'^owner：([^\r\n]+)', text, re.M)
    return {'kind': 'task', 'protocol': 'stage-c/2-draft', 'id': item['task_id'], 'title': title,
            'legacy': {'source': {'uri': path_in(backup / 'files', item['old_path']).as_uri(),
                       'sha256': item['old_hash'], 'description': 'Original unchanged schema-2 task text.'},
                       'protocol': 'schema-2', 'original_state': item['old_state'], 'mapped_state': item['new_state'],
                       'missing': item['missing'], 'owner_hint': owner.group(1).strip() if owner else None},
            'records': [], 'current': {'contract': 0, 'candidate_revision': 0, 'candidate': None,
                                     'owner_assignment': None, 'state': item['new_state'], 'seq': 0}}


def migration_apply(args):
    from .codec import local_uri
    runtime_settings = runtime(args)
    require(args.plan_file, 2, 'PLAN', 'Use a fixed approved migration plan.')
    plan = Validator(asset_root()).check(loads(Path(args.plan_file).read_bytes()))
    require(plan['kind'] == 'migration-plan' and plan['mode'] == 'approved' and plan['approval'] and
            plan['isolation_evidence'] and not plan['issues'], 6, 'PLAN_APPROVAL', 'Approved plan, isolation and no blocking issues required.')
    bootstrap_policy(plan['policy_proposal'])
    repo = Path(args.root or args.repo or Path.cwd()).resolve()
    common = common_dir(repo)
    require(os.fsdecode(git(repo, 'symbolic-ref', 'HEAD').strip()) == 'refs/heads/' + os.environ.get('TASK_BRANCH', 'task-center'),
            7, 'BRANCH', 'Migration must use the dedicated task-center branch.')
    backup = outside(repo, common, local_uri(plan['backup_uri']))
    evidence(plan['backup_manifest'])
    evidence(plan['isolation_evidence'])
    evidence(plan['approval']['source'])
    require(plan['approval']['identity'] == plan['policy_proposal']['decision']['identity'],
            3, 'APPROVAL', 'Migration approver differs from explicit policy maintainer.')
    manifest = loads(evidence(plan['backup_manifest']))
    require(manifest['source_commit'] == plan['source_commit'] and
            sha((backup / 'source.bundle').read_bytes()) == manifest['bundle_sha256'], 11, 'BACKUP', 'Backup commit/bundle differs.')
    git(repo, 'bundle', 'verify', str(backup / 'source.bundle'))
    old_paths = git(repo, 'ls-tree', '-r', '--name-only', plan['source_commit']).decode().splitlines()
    require(set(old_paths) == set(manifest['files']), 11, 'BACKUP', 'Backup asset coverage differs.')
    for p, digest in manifest['files'].items():
        require(sha(path_in(backup / 'files', p).read_bytes()) == digest and
                sha(git(repo, 'show', plan['source_commit'] + ':' + p)) == digest, 11, 'BACKUP', 'Backup file differs.')
    files = assets()
    files.update({'.task-center/policy.json': dumps(plan['policy_proposal']),
                  '.task-center/version': version_bytes(plan['source_revision']),
                  '.task-center/next-id': (plan['next_id'] + '\n').encode(),
                  'docs/tasks/INDEX.md': b'# Task index\n\nImported tasks require explicit evidence verification.\n'})
    ids = set()
    legacy_paths = {p for p in old_paths if re.fullmatch(r'docs/tasks/(?:archive/)?[0-9]+-[a-z0-9][a-z0-9-]*\.md', p)}
    require({x['old_path'] for x in plan['items']} == legacy_paths and len(plan['items']) == len(legacy_paths),
            2, 'PLAN_COVERAGE', 'Every active/archive original task must be converted exactly once.')
    for item in plan['items']:
        require(item['task_id'] not in ids and item['new_state'] is not None and item['new_hash'] is not None,
                2, 'PLAN_ITEM', 'Incomplete/duplicate migration item.')
        ids.add(item['task_id'])
        original = path_in(backup / 'files', item['old_path']).read_bytes()
        original_text = original.decode('utf-8-sig')
        original_state = re.search(r'^状态：([^\r\n]+)', original_text, re.M)
        require(original_state is not None, 2, 'LEGACY_STATE', 'Original state missing.')
        state = original_state.group(1).strip()
        effective = state
        if state == '阻塞':
            prior = re.search(r'^阻塞前状态：([^\r\n]+)', original_text, re.M)
            effective = prior.group(1).strip() if prior else ''
        mapping = {'待办': 'todo', '已认领': 'todo', '进行中': 'active', '待审核': 'verifying',
                   '待测试': 'verifying', '待合并': 'verifying', '已完成': 'done', '已取消': 'canceled'}
        expected_state = mapping.get(effective)
        match = re.fullmatch(r'docs/tasks/(?:archive/)?([0-9]+)-[a-z0-9][a-z0-9-]*\.md', item['old_path'])
        expected_id = str(int(match.group(1)))
        expected_path = 'docs/tasks/' + ('archive/' if expected_state in ('done', 'canceled') else '') + expected_id + '.json'
        require(expected_state is not None and item['task_id'] == expected_id and item['old_state'] == state and
                item['new_state'] == expected_state and item['new_path'] == expected_path and
                item['old_hash'] == manifest['files'][item['old_path']],
                2, 'PLAN_TRANSFORMATION', 'Plan cannot reinterpret states, IDs or canonical paths.')
        raw = dumps(legacy_document(item, backup))
        require(sha(raw) == item['new_hash'], 11, 'PLAN_HASH', 'Migration output changed after approval.')
        files[item['new_path']] = raw
    original_next = int(path_in(backup / 'files', '.task-center/next-id').read_text().strip())
    require(int(plan['next_id']) >= max(original_next, max(map(int, ids), default=0) + 1),
            2, 'NEXT_ID', 'Migration must preserve the original allocation high-water mark.')
    branch = os.fsdecode(git(repo, 'symbolic-ref', 'HEAD').strip())
    with install_lock(common, {'identity': plan['approval']['identity'], 'run': 'migration'}):
        require(not (common / 'task-center-v2/administration.pending').exists(), 10, 'ADMIN_RECOVERY', 'Recover the previous administration operation first.')
        require(os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip()) == plan['source_commit'] and
                not git(repo, 'status', '--porcelain', '--untracked-files=all').strip(), 4, 'SOURCE_CHANGED', 'Source changed since preview.')
        for directory in [common / 'task-center-runtime/transactions', common / 'task-center-v2/pending.json']:
            require(not directory.exists() or (directory.is_dir() and not any(directory.iterdir())),
                    10, 'PENDING', 'Resolve old/new recovery transactions before migration.')
        new = create_commit(repo, files, plan['source_commit'], 'docs(tasks): explicitly migrate schema 2 to 3')
        changes = []
        for p in sorted(set(old_paths) | set(files)):
            before = git(repo, 'show', plan['source_commit'] + ':' + p) if p in old_paths else None
            after = files.get(p)
            changes.append({'path': p, 'before': sha(before) if before is not None else None, 'after': sha(after) if after is not None else None})
        journal = {'kind': 'migration-journal', 'source': plan['source_commit'], 'new': new,
                   'branch': branch, 'backup': plan['backup_uri'], 'plan': plan,
                   'changes': changes, 'state': 'objects-ready'}
        journal_path = common / 'task-center-v2/migration-journal.json'
        atomic(journal_path, dumps(journal))
        atomic(common / 'task-center-v2/administration.pending', b'migration\n')
        git(repo, 'update-ref', branch, new, plan['source_commit'], fail=4)
        journal['state'] = 'ref-updated'
        atomic(journal_path, dumps(journal))
        materialize_migration(repo, journal)
        atomic(common / 'task-center-v2/runtime.json', dumps(runtime_settings))
        atomic(common / 'task-center-v2/install-path', (str(repo) + '\n').encode())
        journal['state'] = 'complete'
        atomic(journal_path, dumps(journal))
        (common / 'task-center-v2/administration.pending').unlink()
        return {'kind': 'migration-result', 'commit': new, 'backup': plan['backup_uri'],
                'tasks': len(plan['items']), 'missing_evidence_preserved': True}


def materialize_migration(repo, journal):
    require(os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip()) == journal['new'], 11, 'RECOVERY_REF', 'Migration ref is uncertain.')
    index = os.fsdecode(git(repo, 'write-tree').strip())
    before = os.fsdecode(git(repo, 'rev-parse', journal['source'] + '^{tree}').strip())
    after = os.fsdecode(git(repo, 'rev-parse', journal['new'] + '^{tree}').strip())
    require(index in (before, after), 11, 'RECOVERY_INDEX', 'User index changed during migration.')
    pending = []
    for item in journal['changes']:
        p = path_in(repo, item['path'])
        actual = sha(p.read_bytes()) if p.is_file() else None
        require(actual in (item['before'], item['after']), 11, 'RECOVERY_FILE', 'Unknown file changes during migration.')
        raw = git(repo, 'show', journal['new'] + ':' + item['path']) if item['after'] is not None else None
        require(raw is None or sha(raw) == item['after'], 11, 'RECOVERY_HASH', 'New asset hash differs.')
        pending.append((item, p, actual, raw))
    for item, p, actual, raw in pending:
        if item['after'] is None:
            if p.exists():
                p.unlink()
        elif actual != item['after']:
            atomic(p, raw)
    git(repo, 'read-tree', journal['new'])


def execute(args):
    if args.command == 'install-recover':
        return install_recover(args)
    if args.command.startswith('install'):
        return install(args)
    if args.command == 'migrate-preview':
        return migration_preview(args)
    if args.command == 'migrate-apply':
        return migration_apply(args)
    if args.command == 'migrate-recover':
        return migration_recover(args)
    if args.command == 'restore-preview':
        return restore_preview(args)
    if args.command == 'restore-apply':
        return restore_apply(args)
    if args.command == 'restore-recover':
        return restore_recover(args)
    raise Fault(2, 'COMMAND', 'Unknown administrative command.')


def current_maintainer(args, repo, commit=None):
    require(args.actor_file, 3, 'ACTOR', 'An explicit active maintainer actor file is required.')
    actor = loads(Path(args.actor_file).read_bytes())
    policy = loads(git(repo, 'show', (commit or 'HEAD') + ':.task-center/policy.json'))
    Validator(asset_root()).check(policy)
    auth.active(policy, actor)
    auth.permit(policy, actor, 'policy.update', '*')
    return actor, policy


def migration_recover(args):
    repo = Path(args.root or args.repo or Path.cwd()).resolve()
    runtime(args)
    common = common_dir(repo)
    administration_guard(common, 'migration')
    journal_file = common / 'task-center-v2/migration-journal.json'
    require(journal_file.is_file(), 10, 'MIGRATION_JOURNAL', 'No migration journal.')
    journal = loads(journal_file.read_bytes())
    head = os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip())
    require(head in (journal['source'], journal['new']), 11, 'RECOVERY_REF', 'Successor/unknown ref requires a separate recovery plan.')
    actor, policy = current_maintainer(args, repo, journal['new'])
    if not args.apply and not args.abort:
        return {'kind': 'migration-recovery-preview', 'head': head, 'journal': journal,
                'choices': ['materialize'] if head == journal['new'] else ['abort-isolated-build']}
    if args.lock_token:
        from .cli import isolate_lock
        isolate_lock(common, policy, actor, args.lock_token, args.isolation_file)
    with install_lock(common, actor):
        require(os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip()) == head, 4, 'RECOVERY_REF', 'Ref changed during recovery.')
        if args.abort:
            require(head == journal['source'] and not git(repo, 'status', '--porcelain').strip(),
                    11, 'RECOVERY_CHOICE', 'Only unchanged uncommitted migration can be aborted.')
            journal['state'] = 'aborted'
        else:
            require(head == journal['new'], 11, 'RECOVERY_CHOICE', 'No confirmed new commit to materialize.')
            materialize_migration(repo, journal)
            settings = runtime(args)
            atomic(common / 'task-center-v2/runtime.json', dumps(settings))
            atomic(common / 'task-center-v2/install-path', (str(repo) + '\n').encode())
            journal['state'] = 'complete'
        atomic(journal_file, dumps(journal))
        marker = common / 'task-center-v2/administration.pending'
        if marker.exists():
            marker.unlink()
    return {'kind': 'migration-recovery-result', 'state': journal['state'], 'head': head}


def restore_preview(args):
    from .codec import local_uri
    repo = Path(args.root or args.repo or Path.cwd()).resolve()
    runtime(args)
    common = common_dir(repo)
    restore_pending_guard(common)
    actor, _ = current_maintainer(args, repo)
    file = common / 'task-center-v2/migration-journal.json'
    require(file.is_file(), 10, 'MIGRATION_JOURNAL', 'No migration journal.')
    journal = loads(file.read_bytes())
    head = os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip())
    require(head == journal['new'] and journal['state'] == 'complete',
            6, 'POST_MIGRATION_FACTS', 'Post-migration commits exist or migration is incomplete; do not overwrite successor facts.')
    require(not git(repo, 'status', '--porcelain', '--untracked-files=all').strip(), 11, 'DIRTY', 'Source has uncommitted work.')
    backup = outside(repo, common, local_uri(journal['backup']))
    manifest = loads(evidence(journal['plan']['backup_manifest']))
    return {'kind': 'restore-plan', 'expected_head': head, 'source_commit': journal['source'],
            'branch': journal['branch'], 'backup_uri': backup.as_uri(),
            'backup_manifest': journal['plan']['backup_manifest'], 'files': manifest['files'],
            'requested_by': actor, 'new_approval_required': True}


def restore_apply(args):
    from .codec import local_uri
    repo = Path(args.root or args.repo or Path.cwd()).resolve()
    settings = runtime(args)
    common = common_dir(repo)
    actor, policy = current_maintainer(args, repo)
    require(args.plan_file and args.approval_file, 3, 'RESTORE_APPROVAL', 'Fixed restore plan and new explicit approval required.')
    plan = loads(Path(args.plan_file).read_bytes())
    allowed = {'kind', 'expected_head', 'source_commit', 'branch', 'backup_uri', 'backup_manifest', 'files', 'requested_by', 'new_approval_required'}
    require(set(plan) == allowed and plan['kind'] == 'restore-plan', 2, 'RESTORE_PLAN', 'Unknown or incomplete restore plan.')
    current = restore_preview(args)
    require(plan == current, 4, 'RESTORE_PLAN', 'Restore preview changed; create a new approved plan.')
    confirm = loads(Path(args.approval_file).read_bytes())
    Validator(asset_root()).check(dict(policy, decision=confirm))
    require(confirm['identity'] in {g['identity'] for g in policy['body']['grants'] if 'policy.update' in g['actions'] and '*' in g['tasks']},
            3, 'RESTORE_APPROVAL', 'Authorized maintainer confirmation required.')
    evidence(confirm['source'])
    backup = outside(repo, common, local_uri(plan['backup_uri']))
    evidence(plan['backup_manifest'])
    files = {}
    for p, digest in plan['files'].items():
        raw = path_in(backup / 'files', p).read_bytes()
        require(sha(raw) == digest and sha(git(repo, 'show', plan['source_commit'] + ':' + p)) == digest,
                11, 'BACKUP_CHANGED', 'Restore source does not match verified backup.')
        files[p] = raw
    with install_lock(common, actor):
        restore_pending_guard(common)
        require(os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip()) == plan['expected_head'] and
                not git(repo, 'status', '--porcelain', '--untracked-files=all').strip(), 4, 'RESTORE_RACE', 'Source changed after restore approval.')
        require(not (common / 'task-center-v2/administration.pending').exists(), 10, 'ADMIN_RECOVERY', 'Recover the previous administration operation first.')
        new = create_commit(repo, files, plan['expected_head'], 'docs(tasks): explicitly restore pre-migration assets')
        names = git(repo, 'ls-tree', '-r', '--name-only', plan['expected_head']).decode().splitlines()
        changes = []
        for p in sorted(set(names) | set(files)):
            before = git(repo, 'show', plan['expected_head'] + ':' + p) if p in names else None
            after = files.get(p)
            changes.append({'path': p, 'before': sha(before) if before is not None else None, 'after': sha(after) if after is not None else None})
        journal = {'kind': 'restore-journal', 'source': plan['expected_head'], 'new': new,
                   'branch': plan['branch'], 'plan': plan, 'changes': changes,
                   'approval': confirm, 'state': 'objects-ready'}
        file = common / 'task-center-v2/restore-journal.json'
        atomic(file, dumps(journal))
        atomic(common / 'task-center-v2/administration.pending', b'restore\n')
        git(repo, 'update-ref', plan['branch'], new, plan['expected_head'], fail=4)
        journal['state'] = 'ref-updated'
        atomic(file, dumps(journal))
        materialize_migration(repo, journal)
        journal['state'] = 'complete'
        atomic(file, dumps(journal))
        (common / 'task-center-v2/administration.pending').unlink()
        return {'kind': 'restore-result', 'commit': new, 'restored_source': plan['source_commit'],
                'no_successor_facts_discarded': True}


def install_recover(args):
    repo = Path(args.repo or Path.cwd()).resolve()
    settings = runtime(args)
    common = common_dir(repo)
    administration_guard(common, 'install')
    file = common / 'task-center-v2/install-journal.json'
    require(file.is_file(), 10, 'INSTALL_JOURNAL', 'No installation journal.')
    journal = loads(file.read_bytes())
    plan, commit = journal['plan'], journal['new_commit']
    require(plan['repo'] == str(repo) and plan['runtime'] == settings, 11, 'INSTALL_JOURNAL', 'Repository/runtime differs from approved install.')
    require(args.actor_file, 3, 'ACTOR', 'Explicit maintenance actor required.')
    actor = loads(Path(args.actor_file).read_bytes())
    policy = loads(git(repo, 'show', commit + ':.task-center/policy.json'))
    auth.active(policy, actor)
    auth.permit(policy, actor, 'policy.update', '*')
    evidence(journal['approval']['source'])
    head = subprocess_ref(repo, plan['branch'])
    require(head in (None, commit), 11, 'INSTALL_REF', 'Target branch has unexpected successor commits.')
    if not args.apply:
        return {'kind': 'install-recovery-preview', 'journal': journal, 'head': head}
    if args.lock_token:
        from .cli import isolate_lock
        isolate_lock(common, policy, actor, args.lock_token, args.isolation_file)
    with install_lock(common, actor):
        require(subprocess_ref(repo, plan['branch']) == head, 4, 'INSTALL_RACE', 'Install branch changed.')
        if head is None:
            git(repo, 'update-ref', plan['branch'], commit, '0' * len(commit), fail=4)
        destination = Path(plan['destination']).resolve()
        registered = git(repo, 'worktree', 'list', '--porcelain').decode('utf-8')
        if str(destination).replace('\\', '/') not in registered.replace('\\', '/'):
            require(not destination.exists() or not any(destination.iterdir()), 11, 'INSTALL_DESTINATION', 'Unknown destination contents; preserve them.')
            git(repo, 'worktree', 'add', str(destination), plan['branch'].removeprefix('refs/heads/'))
        require(common_dir(destination) == common and os.fsdecode(git(destination, 'rev-parse', 'HEAD').strip()) == commit,
                11, 'INSTALL_DESTINATION', 'Installed worktree does not match the expected clone/commit.')
        require(not git(destination, 'ls-files', '--others', '--exclude-standard').strip(),
                11, 'INSTALL_DIRTY', 'Unknown user files are preserved; inspect before finishing installation.')
        require(git(destination, 'write-tree').strip() == git(destination, 'rev-parse', commit + '^{tree}').strip(),
                11, 'INSTALL_DIRTY', 'User index differs from the installation commit.')
        materialize = []
        for p, digest in plan['files'].items():
            target = path_in(destination, p)
            require(target.is_file(), 11, 'INSTALL_FILE', 'Missing installation asset requires explicit inspection.')
            raw = git(destination, 'show', commit + ':' + p)
            require(sha(raw) == digest, 11, 'INSTALL_HASH', 'Committed installation asset differs.')
            actual = target.read_bytes()
            require(actual.replace(b'\r\n', b'\n') == raw.replace(b'\r\n', b'\n'),
                    11, 'INSTALL_FILE', 'Unknown user changes; do not overwrite.')
            materialize.append((target, actual, raw))
        for target, actual, raw in materialize:
            if actual != raw:
                atomic(target, raw)
        require(not git(destination, 'status', '--porcelain', '--untracked-files=all').strip(),
                11, 'INSTALL_DIRTY', 'Installation is not clean; preserve the pending marker.')
        atomic(common / 'task-center-v2/runtime.json', dumps(settings))
        atomic(common / 'task-center-v2/install-path', (str(destination) + '\n').encode())
        journal['state'] = 'complete'
        atomic(file, dumps(journal))
        marker = common / 'task-center-v2/administration.pending'
        if marker.exists():
            marker.unlink()
    return {'kind': 'install-recovery-result', 'commit': commit, 'destination': str(destination)}


def restore_recover(args):
    repo = Path(args.root or args.repo or Path.cwd()).resolve()
    runtime(args)
    common = common_dir(repo)
    administration_guard(common, 'restore')
    file = common / 'task-center-v2/restore-journal.json'
    require(file.is_file(), 10, 'RESTORE_JOURNAL', 'No restore journal.')
    journal = loads(file.read_bytes())
    actor, policy = current_maintainer(args, repo, journal['source'])
    head = os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip())
    require(head in (journal['source'], journal['new']), 11, 'RECOVERY_REF', 'Unknown successor ref; preserve all restore data.')
    if not args.apply and not args.abort:
        return {'kind': 'restore-recovery-preview', 'head': head, 'journal': journal}
    if args.lock_token:
        from .cli import isolate_lock
        isolate_lock(common, policy, actor, args.lock_token, args.isolation_file)
    with install_lock(common, actor):
        require(os.fsdecode(git(repo, 'rev-parse', 'HEAD').strip()) == head, 4, 'RECOVERY_REF', 'Restore ref changed.')
        if args.abort:
            require(head == journal['source'] and not git(repo, 'status', '--porcelain').strip(),
                    11, 'RECOVERY_CHOICE', 'Cannot abort a committed or modified restore.')
            journal['state'] = 'aborted'
        else:
            require(head == journal['new'], 11, 'RECOVERY_CHOICE', 'Restore commit is not confirmed.')
            materialize_migration(repo, journal)
            journal['state'] = 'complete'
        atomic(file, dumps(journal))
        marker = common / 'task-center-v2/administration.pending'
        if marker.exists():
            marker.unlink()
    return {'kind': 'restore-recovery-result', 'head': head, 'state': journal['state']}
