"""Execute the frozen structural/lexical/K vectors, without treating prose as code."""
import copy
import json
import unittest
from pathlib import Path
from test_structured_task_center import ASSETS, REPO, World
from taskcore.codec import Fault, canonical, loads, local_uri, sha
from taskcore.validation import Validator


def pointer(document, path):
    for key in path.strip('/').split('/'):
        key = key.replace('~1', '/').replace('~0', '~')
        document = document[int(key)] if isinstance(document, list) else document[key]
    return document


class FrozenVectors(unittest.TestCase):
    def test_runtime_annotations_do_not_change_frozen_constraints(self):
        original = json.loads((REPO / 'design/stage-c/protocol.schema.json').read_bytes())
        installed = json.loads((ASSETS / 'protocol.schema.json').read_bytes())
        self.assertEqual(installed['$id'], 'urn:local-task-center:protocol:3')
        for value in [original, installed]:
            value.pop('$id'); value.pop('$comment')
        self.assertEqual(installed, original)

    def test_full_sha256_object_ids_and_short_prefix_rejection(self):
        from taskcore.engine import Engine
        w = World(object_format='sha256')
        reference = w.store.policy_ref()
        self.assertEqual(len(reference['commit']), 64)
        self.assertEqual(len(reference['blob']), 64)
        self.assertEqual(w.store.policy_at(reference)['revision'], 1)
        short = dict(reference, commit=reference['commit'][:40])
        with self.assertRaises(Fault) as caught:
            w.store.policy_at(short)
        self.assertEqual(caught.exception.code, 2)
        artifact = copy.deepcopy(w.requests[1]['actions'][0]['payload']['artifacts'][0])
        artifact.update(kind='git', git_object=reference['commit'][:40])
        engine = Engine(w.store, w.validator)
        with self.assertRaises(Fault) as caught:
            engine.artifact(artifact)
        self.assertEqual(caught.exception.code, 2)
        artifact['git_object'] = reference['commit']
        engine.artifact(artifact)

    def test_file_uri_percent_escape_is_decoded_once(self):
        p = (REPO / 'literal%20 space+中文.txt').resolve()
        self.assertEqual(local_uri(p.as_uri()), p)
        with self.assertRaises(Fault):
            local_uri(p.as_uri() + '#ignored-fragment')

    def test_frozen_67_structures_11_lexical_and_6_canonical(self):
        validator = Validator(ASSETS)
        vectors = json.loads((REPO / 'design/stage-c/vectors.json').read_text(encoding='utf-8'))
        fixture = json.loads((REPO / 'examples/workflow-stage-c-complete.json').read_text(encoding='utf-8'))
        for case in vectors['schema_cases']:
            with self.subTest(case=case['id']):
                value = copy.deepcopy(pointer(fixture, case['seed']))
                for edit in case['patch']:
                    parent, _, key = edit['path'].rpartition('/')
                    obj = pointer(value, parent) if parent else value
                    key = int(key) if isinstance(obj, list) else key.replace('~1', '/').replace('~0', '~')
                    if edit['op'] == 'remove':
                        del obj[key]
                    else:
                        obj[key] = copy.deepcopy(edit['value'])
                try:
                    validator.check(value)
                    valid = True
                except Fault:
                    valid = False
                self.assertEqual(valid, case['schema_valid'])
        for case in vectors['lexical_cases']:
            with self.subTest(case=case['id']):
                try:
                    loads(case['raw'].encode('utf-8'))
                    valid = True
                except Fault:
                    valid = False
                self.assertEqual(valid, case['valid'])
        for case in vectors['canonical_cases']:
            with self.subTest(case=case['id']):
                encoded = canonical(case['value'])
                self.assertEqual(encoded.hex(), case['utf8_hex'])
                self.assertEqual(sha(encoded), case['sha256'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
