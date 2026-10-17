"""Build an isolated offline runtime from explicitly hashed local wheels.

This tool never resolves or downloads dependencies. Network acquisition and
security review are separate release preparation steps.
"""
import argparse
import email
import hashlib
import json
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'templates/task-center-v2/scripts'))
from taskcore.validation import VERSIONS


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def inventory(wheelhouse):
    found = {}
    for path in sorted(wheelhouse.glob('*.whl')):
        with zipfile.ZipFile(path) as wheel:
            names = [n for n in wheel.namelist() if n.endswith('.dist-info/METADATA')]
            if len(names) != 1:
                raise ValueError('Wheel has no unique package metadata.')
            metadata = email.message_from_bytes(wheel.read(names[0]))
            name = metadata['Name'].lower().replace('_', '-')
            if name not in VERSIONS or metadata['Version'] != VERSIONS[name] or name in found:
                raise ValueError('Unexpected or duplicate dependency/version: ' + name)
            licenses = [n for n in wheel.namelist() if '.dist-info/' in n and
                        ('license' in n.lower() or n.endswith('/COPYING'))]
            if not licenses:
                raise ValueError('Dependency license texts must be included: ' + name)
            found[name] = {'version': metadata['Version'], 'wheel': path.name,
                           'sha256': digest(path.read_bytes()),
                           'license_expression': metadata.get('License-Expression') or metadata.get('License') or
                           '; '.join(metadata.get_all('Classifier', [])),
                           'license_files': {n: digest(wheel.read(n)) for n in licenses}}
    if set(found) != set(VERSIONS):
        raise ValueError('All six pinned dependencies must be present, without extra wheels.')
    return found


def main():
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=['inventory', 'prepare'])
    p.add_argument('--wheelhouse', type=Path, required=True)
    p.add_argument('--lock', type=Path, required=True)
    p.add_argument('--destination', type=Path)
    args = p.parse_args()
    packages = inventory(args.wheelhouse.resolve())
    if args.mode == 'inventory':
        args.lock.parent.mkdir(parents=True, exist_ok=True)
        args.lock.write_text(json.dumps({'lock_version': 1, 'packages': packages,
                            'release_approved': False, 'security_audit': 'separate review required'},
                            indent=2) + '\n', encoding='utf-8')
        print('Inventory produced; not a release approval.')
        return
    lock = json.loads(args.lock.read_text(encoding='utf-8'))
    if packages != lock['packages']:
        raise ValueError('Wheel metadata/bytes differ from the selected lock.')
    dest = args.destination.resolve()
    if dest.exists() and any(dest.iterdir()):
        raise ValueError('Use an empty destination; never overwrite an installed runtime.')
    dest.mkdir(parents=True, exist_ok=True)
    wheels = [str(args.wheelhouse.resolve() / row['wheel']) for row in packages.values()]
    subprocess.run([sys.executable, '-I', '-m', 'pip', '--isolated', 'install', '--disable-pip-version-check',
                    '--no-index', '--no-deps', '--no-compile', '--target', str(dest), *wheels], check=True)
    files = {f.relative_to(dest).as_posix(): digest(f.read_bytes()) for f in sorted(dest.rglob('*')) if f.is_file()}
    runtime = {'lock_version': 1, 'packages': packages, 'files': files,
               'release_approved': lock.get('release_approved') is True,
               'security_audit': lock.get('security_audit', 'unknown')}
    raw = (json.dumps(runtime, indent=2) + '\n').encode()
    (dest / 'runtime-lock.json').write_bytes(raw)
    print('Prepared isolated runtime; SHA256=' + digest(raw))


if __name__ == '__main__':
    main()
