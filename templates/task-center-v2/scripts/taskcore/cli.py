import argparse
import contextlib
import ctypes
import json
import os
import socket
import sys
from pathlib import Path
from . import auth
from .codec import Fault, atomic, dumps, evidence, loads, require
from .engine import Engine, gap, response
from .store import Store, git
from .validation import Validator


def discover(explicit):
    if explicit:
        return Path(explicit).resolve()
    here = Path.cwd()
    common = Path(os.fsdecode(git(here, 'rev-parse', '--git-common-dir').strip()))
    common = (here / common).resolve() if not common.is_absolute() else common.resolve()
    candidate = os.environ.get('TASK_CENTER_PATH')
    if not candidate:
        registration = common / 'task-center-v2' / 'install-path'
        if registration.is_file():
            candidate = registration.read_text(encoding='utf-8').strip()
    if not candidate:
        blocks = git(here, 'worktree', 'list', '--porcelain').decode('utf-8').split('\n\n')
        branch = 'branch refs/heads/' + os.environ.get('TASK_BRANCH', 'task-center')
        paths = [b.splitlines()[0][9:] for b in blocks if branch in b.splitlines()]
        require(len(paths) == 1, 7, 'DISCOVERY', 'Use --root or configure one local task-center worktree.')
        candidate = paths[0]
    store = Store(candidate)
    require(store.common == common, 7, 'CLONE', 'Discovered task center belongs to another clone.')
    return store.root


def process_alive(owner):
    if owner.get('host') != socket.gethostname():
        return True  # Unknown remote owner: never automatically break its lock.
    pid = owner.get('pid')
    if not isinstance(pid, int) or pid <= 0:
        return True
    if os.name == 'nt':
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return ctypes.get_last_error() != 87
        try:
            code = wintypes.DWORD()
            if not kernel.GetExitCodeProcess(handle, ctypes.byref(code)):
                return True
            return code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def takeover(store, actor, token, isolation):
    policy = loads(store.blob('.task-center/policy.json'))
    isolate_lock(store.common, policy, actor, token, isolation)


@contextlib.contextmanager
def takeover_mutex(common):
    """Serialize lock isolation with an OS lock on a stable, never-renamed inode."""
    from .codec import path_in
    path = path_in(common / 'task-center-v2', 'takeover.guard')
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        if os.fstat(fd).st_size == 0:
            os.write(fd, b'0')
        os.lseek(fd, 0, os.SEEK_SET)
        if os.name == 'nt':
            import msvcrt
            acquire = lambda: msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            release = lambda: msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            acquire = lambda: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            release = lambda: fcntl.flock(fd, fcntl.LOCK_UN)
        try:
            acquire()
        except OSError as exc:
            raise Fault(10, 'LOCK_ISOLATION_BUSY', 'Another recovery is isolating a writer lock.') from exc
        try:
            yield
        finally:
            os.lseek(fd, 0, os.SEEK_SET)
            release()
    finally:
        os.close(fd)


def isolate_lock(common, policy, actor, token, isolation):
    """Version-independent explicit recovery of a dead local writer's lock."""
    auth.active(policy, actor)
    auth.permit(policy, actor, 'policy.update', '*')
    require(token and isolation, 10, 'LOCK_ISOLATION', 'Owner token and explicit isolation evidence are required.')
    evidence(loads(Path(isolation).read_bytes()))
    with takeover_mutex(common):
        lock_path = common / 'task-center-write.lock'
        owner_file = lock_path / 'owner.json'
        require(owner_file.is_file(), 10, 'LOCK_UNKNOWN', 'Unknown/legacy lock: preserve and inspect manually.')
        owner = loads(owner_file.read_bytes())
        require(owner.get('token') == token and not process_alive(owner),
                10, 'LOCK_OWNER', 'Owner is alive/unknown or token changed; do not break its lock.')
        import uuid
        destination = common / 'task-center-v2' / ('isolated-lock-' + uuid.uuid4().hex)
        require(loads(owner_file.read_bytes()).get('token') == token, 10, 'LOCK_OWNER', 'Lock changed.')
        os.rename(lock_path, destination)


def run(args):
    if args.command == 'doctor':
        return {'python': sys.version.split()[0], 'root_hint': args.root,
                'runtime_configured': bool(os.environ.get('TASK_RUNTIME_PATH')),
                'tool_version': 2, 'schema_version': 3,
                'note': 'Dependency/version diagnostics only; no task/policy/receipt data read.'}
    if args.command.startswith(('install', 'migrate', 'restore')):
        from .install import execute
        return execute(args)
    root = discover(args.root)
    store = Store(root)
    config = store.runtime / 'runtime.json'
    if not os.environ.get('TASK_RUNTIME_PATH') and config.is_file():
        settings = loads(config.read_bytes())
        os.environ['TASK_RUNTIME_PATH'] = settings['path']
        os.environ['TASK_RUNTIME_LOCK_SHA256'] = settings['lock_sha256']
    elif config.is_file() and not os.environ.get('TASK_RUNTIME_LOCK_SHA256'):
        settings = loads(config.read_bytes())
        require(Path(os.environ['TASK_RUNTIME_PATH']).resolve() == Path(settings['path']).resolve(),
                8, 'RUNTIME_LOCK', 'Explicit runtime differs from the approved clone runtime.')
        os.environ['TASK_RUNTIME_LOCK_SHA256'] = settings['lock_sha256']
    validator = Validator(root)
    if args.command == 'recover':
        require(args.actor_file, 3, 'ACTOR', 'Recovery requires an explicit current actor file.')
        actor = loads(Path(args.actor_file).read_bytes())
        policy = validator.check(loads(store.blob('.task-center/policy.json')))
        auth.active(policy, actor)
        auth.permit(policy, actor, 'policy.update', '*')
        if args.lock_token:
            takeover(store, actor, args.lock_token, args.isolation_file)
        with store.lock(actor, timeout=args.lock_timeout, recovery=True):
            return store.recovery(apply=args.apply, abort=args.abort)
    file = args.request_file if args.command == 'apply' else args.query_file
    require(file is not None, 2, 'INPUT', 'A UTF-8 request/query file is required.')
    document = validator.check(loads(Path(file).read_bytes()))
    require(document['kind'] == ('request' if args.command == 'apply' else 'query'),
            2, 'INPUT_KIND', 'Use the corresponding apply/query entry point.')
    if args.command == 'query':
        return Engine(store, validator).query(document)
    with store.lock(document['actor'], timeout=args.lock_timeout):
        before = store.snapshot()
        engine = Engine(store, validator, before)
        result, receipt = engine.apply(document)
        if receipt is not None:
            changes = engine.changes(before, receipt)
            result['commit'] = store.commit(before['commit'], changes, document['request_id'], receipt['request_hash'],
                                          '.task-center/receipts/' + document['request_id'] + '.json',
                                          'docs(tasks): apply ' + document['request_id'])
        validator.check(result)
        return result


def parser():
    p = argparse.ArgumentParser(description='Local structured task center; no external dispatch.')
    p.add_argument('command', choices=['doctor', 'apply', 'query', 'recover', 'install-preview', 'install-apply', 'install-recover',
                                      'migrate-preview', 'migrate-apply', 'migrate-recover', 'restore-preview', 'restore-apply', 'restore-recover'])
    for name in ['root', 'request-file', 'query-file', 'response-file', 'actor-file', 'lock-token',
                 'isolation-file', 'repo', 'destination', 'policy-file', 'runtime-dir', 'backup-dir',
                 'plan-file', 'approval-file', 'source-revision']:
        p.add_argument('--' + name)
    p.add_argument('--lock-timeout', type=float, default=10)
    recovery_choice = p.add_mutually_exclusive_group()
    recovery_choice.add_argument('--apply', action='store_true')
    recovery_choice.add_argument('--abort', action='store_true')
    p.add_argument('--candidate', action='store_true', help='Explicitly use an unreleased build in an isolated fixture.')
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    result = None
    code = 0
    try:
        result = run(args)
    except Fault as exc:
        code = exc.code
        result = response('indeterminate' if code == 9 else 'rejected')
        result.update(exit=code, errors=[gap(exc.tag, None, str(exc))])
    except (OSError, KeyError, ValueError, TypeError) as exc:
        code = 9
        result = response('indeterminate')
        result.update(exit=9, errors=[gap('IO_OR_STATE', None, 'Operation could not be confirmed; inspect recovery state.')])
        print(type(exc).__name__, file=sys.stderr)
    try:
        raw = dumps(result)
        if args.response_file:
            atomic(args.response_file, raw)
        else:
            sys.stdout.buffer.write(raw)
    except OSError:
        print('Response delivery failed; retry the original request ID or query the receipt.', file=sys.stderr)
        return 9
    return code
