"""Refresh the immutable installation asset manifest, preserving frozen C data."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'templates/task-center-v2'
source = (ROOT / 'design/stage-c/protocol.schema.json').read_bytes()
if hashlib.sha256(source).hexdigest() != 'f0ac6ec854ce0ffc4fee0c4f5228f8ffd52add6905c0b95e449247b843253c9d':
    raise SystemExit('Frozen schema changed; review compatibility before rebuilding assets.')
schema = json.loads(source)
# Runtime annotations are generic; every validation constraint remains frozen.
schema['$id'] = 'urn:local-task-center:protocol:3'
schema['$comment'] = 'Structured local task-center schema. Companion semantic rules are mandatory; schema validation alone does not authorize actions.'
(TARGET / 'protocol.schema.json').write_text(json.dumps(schema, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
files = {}
for p in sorted(TARGET.rglob('*')):
    if not p.is_file() or '__pycache__' in p.parts or p.name == 'assets.json':
        continue
    rel = p.relative_to(TARGET).as_posix()
    if rel.startswith('.task-center/') or rel == 'docs/tasks/INDEX.md':
        continue
    files[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
(TARGET / 'assets.json').write_text(json.dumps(files, indent=2) + '\n', encoding='utf-8', newline='\n')
print('Pinned installation assets:', len(files))
