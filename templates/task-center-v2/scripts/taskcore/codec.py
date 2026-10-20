"""Strict protocol encoding and local evidence verification."""
import datetime as dt
import hashlib
import json
import os
import re
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import url2pathname

PROTOCOL = 'stage-c/2-draft'
LIMIT = 8 * 1024 * 1024


class Fault(Exception):
    def __init__(self, code, tag, message):
        super().__init__(message)
        self.code, self.tag = code, tag


def require(ok, code, tag, message):
    if not ok:
        raise Fault(code, tag, message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def loads(raw):
    require(len(raw) <= LIMIT, 2, 'SIZE', 'Document exceeds 8 MiB.')
    try:
        text = raw.decode('utf-8', 'strict')
        require(not text.startswith('\ufeff'), 2, 'BOM', 'UTF-8 BOM is not allowed.')
        depth, quoted, escaped = 0, False, False
        for ch in text:
            if quoted:
                if escaped:
                    escaped = False
                elif ch == '\\':
                    escaped = True
                elif ch == '"':
                    quoted = False
            elif ch == '"':
                quoted = True
            elif ch in '[{':
                depth += 1
                require(depth <= 64, 2, 'DEPTH', 'Document exceeds depth 64.')
            elif ch in ']}':
                depth -= 1

        def pairs(items):
            out = {}
            for k, v in items:
                require(k not in out, 2, 'DUPLICATE_KEY', 'Duplicate object key.')
                out[k] = v
            return out

        def integer(s):
            require(s != '-0', 2, 'NUMBER', 'Negative zero is not allowed.')
            return int(s)

        def noninteger(_):
            raise Fault(2, 'NUMBER', 'Only integer JSON number tokens are allowed.')

        value = json.loads(text, object_pairs_hook=pairs, parse_int=integer,
                           parse_float=noninteger, parse_constant=noninteger)

        def walk(v):
            if isinstance(v, str):
                require(all(not (0xd800 <= ord(c) <= 0xdfff) and
                            (ord(c) >= 32 or c in '\t\r\n') for c in v),
                        2, 'STRING', 'Invalid Unicode scalar/control character.')
            elif isinstance(v, list):
                for child in v:
                    walk(child)
            elif isinstance(v, dict):
                for k, child in v.items():
                    walk(k)
                    walk(child)
                if v.get('kind') == 'known' and 'utc' in v:
                    try:
                        stamp = dt.datetime.strptime(v['utc'], '%Y-%m-%dT%H:%M:%SZ')
                        require(stamp.strftime('%Y-%m-%dT%H:%M:%SZ') == v['utc'],
                                2, 'TIME', 'Noncanonical calendar time.')
                    except ValueError as exc:
                        raise Fault(2, 'TIME', 'Invalid UTC calendar time.') from exc
        walk(value)
        return value
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise Fault(2, 'JSON', 'Invalid strict JSON document.') from exc


def dumps(value):
    raw = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    require(len(raw) <= LIMIT, 2, 'SIZE', 'Serialized document exceeds 8 MiB.')
    return raw


def canonical(v):
    if isinstance(v, str):
        out = ['"']
        for ch in v:
            n = ord(ch)
            out.append('\\u%04x' % n if n < 32 else '\\"' if ch == '"'
                       else '\\\\' if ch == '\\' else ch)
        return (''.join(out) + '"').encode('utf-8')
    if isinstance(v, dict):
        require(all(k.isascii() for k in v), 2, 'KEY', 'Protocol keys must be ASCII.')
        return b'{' + b','.join(canonical(k) + b':' + canonical(v[k]) for k in sorted(v)) + b'}'
    if isinstance(v, list):
        return b'[' + b','.join(canonical(x) for x in v) + b']'
    if v is True:
        return b'true'
    if v is False:
        return b'false'
    if v is None:
        return b'null'
    require(type(v) is int, 2, 'TYPE', 'Unsupported canonical value.')
    return str(v).encode('ascii')


def now():
    return {'kind': 'known', 'utc': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}


def atomic(path, raw):
    import uuid
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    try:
        with open(temp, 'xb') as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
        if os.name != 'nt':
            fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
    finally:
        if temp.exists():
            temp.unlink()


def path_in(root, relative):
    require(isinstance(relative, str) and '\\' not in relative and ':' not in relative,
            2, 'PATH', 'Only safe relative slash paths are allowed.')
    parts = relative.split('/')
    require(all(p and p not in ('.', '..') for p in parts), 2, 'PATH', 'Unsafe path segment.')
    root = Path(root).resolve()
    p = root
    for part in parts:
        p = p / part
        require(not p.is_symlink() and not (hasattr(p, 'is_junction') and p.is_junction()),
                11, 'REPARSE', 'Managed paths must not be links or junctions.')
        if os.name == 'nt' and p.exists():
            import stat
            require(not (p.lstat().st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT),
                    11, 'REPARSE', 'Managed reparse point rejected.')
    require(p.resolve().is_relative_to(root), 2, 'PATH', 'Path escapes managed root.')
    return p


def local_uri(uri):
    parsed = urlparse(uri)
    require(parsed.scheme == 'file' and parsed.netloc in ('', 'localhost') and not parsed.query and not parsed.fragment,
            6, 'EVIDENCE_LOCAL', 'Prepare a stable local file URI before the transaction.')
    # url2pathname already decodes percent escapes on both supported OS families.
    return Path(url2pathname(parsed.path))


def evidence(source):
    p = local_uri(source['uri'])
    try:
        raw = p.read_bytes()
    except OSError as exc:
        raise Fault(6, 'EVIDENCE_MISSING', 'Evidence is not readable.') from exc
    require(sha(raw) == source['sha256'], 6, 'EVIDENCE_CHANGED', 'Evidence byte hash changed.')
    return raw


def sources(value):
    if isinstance(value, dict):
        if set(value) == {'uri', 'sha256', 'description'}:
            evidence(value)
        else:
            for child in value.values():
                sources(child)
    elif isinstance(value, list):
        for child in value:
            sources(child)
