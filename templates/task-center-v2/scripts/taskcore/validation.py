"""Pinned offline JSON Schema validation."""
import importlib.metadata
import os
import sys
from pathlib import Path
from .codec import Fault, loads, require, sha

VERSIONS = {'jsonschema': '4.23.0', 'attrs': '26.1.0', 'jsonschema-specifications': '2025.9.1',
            'referencing': '0.37.0', 'rpds-py': '2026.9.1', 'typing-extensions': '4.16.0'}


class Validator:
    def __init__(self, asset_root):
        require((3, 11) <= sys.version_info[:2] <= (3, 13), 8, 'PYTHON', 'Supported Python: 3.11-3.13.')
        runtime = os.environ.get('TASK_RUNTIME_PATH')
        require(runtime is not None, 8, 'RUNTIME', 'Set TASK_RUNTIME_PATH to the approved offline runtime.')
        runtime = Path(runtime).resolve()
        require(runtime.is_dir(), 8, 'RUNTIME', 'Offline runtime directory is missing.')
        try:
            lock_raw = (runtime / 'runtime-lock.json').read_bytes()
            require(sha(lock_raw) == os.environ.get('TASK_RUNTIME_LOCK_SHA256'),
                    8, 'RUNTIME_LOCK', 'The approved runtime fingerprint is missing or differs.')
            lock = loads(lock_raw)
            from .codec import path_in
            for relative, digest in lock['files'].items():
                require(sha(path_in(runtime, relative).read_bytes()) == digest,
                        8, 'RUNTIME_HASH', 'Offline runtime file differs from the approved fingerprint.')
        except OSError as exc:
            raise Fault(8, 'RUNTIME_LOCK', 'Hashed offline runtime is missing.') from exc
        sys.path.insert(0, str(runtime))
        try:
            for name, version in VERSIONS.items():
                require(importlib.metadata.version(name) == version, 8, 'DEPENDENCY_VERSION',
                        'Offline runtime dependency version does not match the release lock.')
            from jsonschema import Draft202012Validator
            import jsonschema
            require(Path(jsonschema.__file__).resolve().is_relative_to(runtime),
                    8, 'RUNTIME_ORIGIN', 'Validator was imported outside the approved runtime.')
            from referencing import Registry
            raw = (Path(asset_root) / 'protocol.schema.json').read_bytes()
            manifest = loads((Path(asset_root) / 'assets.json').read_bytes())
            require(sha(raw) == manifest['protocol.schema.json'], 8, 'SCHEMA_HASH', 'Installed schema hash differs.')
            schema = loads(raw)
            Draft202012Validator.check_schema(schema)
            def offline(_):
                raise Fault(8, 'REMOTE_REF', 'Remote schema retrieval is disabled.')
            self.validator = Draft202012Validator(schema, registry=Registry(retrieve=offline))
        except (ImportError, importlib.metadata.PackageNotFoundError, OSError) as exc:
            raise Fault(8, 'DEPENDENCY', 'Approved offline runtime/schema is not available.') from exc

    def check(self, value):
        errors = list(self.validator.iter_errors(value))
        require(not errors, 2, 'SCHEMA', 'Document does not match the closed protocol schema.')
        return value
