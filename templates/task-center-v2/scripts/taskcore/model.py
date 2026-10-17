"""Rebuildable task facts. The cached current object is never an input."""
from copy import deepcopy
from .codec import canonical, require


class Model:
    def __init__(self, document, store):
        self.doc, self.store = document, store
        self.contracts, self.assignments, self.assignment_history = {}, {}, {}
        self.candidates, self.results, self.issues, self.blocks, self.deliveries = {}, {}, {}, {}, {}
        self.applicability, self.dispositions, self.consumptions, self.clearances = [], [], [], []
        self.parent = None
        self.contract_rev = self.candidate_rev = 0
        self.candidate = self.owner = None
        self.state = document['legacy']['mapped_state'] if document['legacy'] else 'todo'
        self.legacy = document['legacy']
        for record in document['records']:
            self.replay(record)

    @property
    def contract(self):
        return self.contracts.get(self.contract_rev)

    def contract_value(self, spec):
        policy = self.store.policy_at(spec['defaults']['policy'])
        profiles = [p for p in policy['body']['defaults'] if p['id'] == spec['defaults']['profile']]
        require(len(profiles) == 1, 2, 'DEFAULT_REF', 'Pinned default profile missing.')
        value = deepcopy(profiles[0])
        value.pop('id')
        value.update(spec['overrides'])
        value.update({k: deepcopy(v) for k, v in spec.items() if k not in ('overrides',)})
        value.setdefault('completion_children', [])
        return value

    def replay(self, record):
        a = record['action']
        op, p = a['op'], deepcopy(a['payload'])
        actor = record['actor']
        if op in ('task.open', 'contract.revise'):
            self.contract_rev += 1
            self.contracts[self.contract_rev] = self.contract_value(p['contract'])
            if op == 'task.open':
                self.parent = p.get('parent')
            else:
                self.state = 'active'
        elif op == 'assignment.set':
            aid = p['id']
            if aid in self.assignments:
                old = self.assignments[aid]
                self.assignment_history[(aid, old['revision'])] = deepcopy(old)
            p.update(revision=a['expected']['assignment'] + 1, accepted_run=None)
            self.assignments[aid] = p
            if p['role'] == 'owner':
                if self.owner is not None and self.owner != aid:
                    self.assignments[self.owner]['revoked'] = True
                self.owner = aid
        elif op == 'assignment.accept':
            self.assignments[p['binding']['assignment']]['accepted_run'] = actor['run']
        elif op == 'work.begin':
            self.state = 'active'
        elif op == 'candidate.submit':
            p['record'] = record
            p['consumes'] = deepcopy(self.consumptions)
            self.candidates[p['id']] = p
            self.candidate_rev += 1
            self.candidate = p['id']
            self.state = 'verifying'
        elif op in ('result.append', 'result.record-historical'):
            result = p if op == 'result.append' else p['result']
            if result['id'] not in self.results:
                result['record'] = record
                result['historical_unverified'] = p.get('unverified', []) if op.endswith('historical') else []
                self.results[result['id']] = result
            if self.state == 'delivering' and any(x['outcome'] != 'pass' for x in result['coverage']):
                c = self.contracts.get(result['target']['contract_revision'])
                before = {x['id'] for x in c['requirements'] if x['gate'] == 'before-delivery'} if c else set()
                if self.candidate == result['target']['candidate'] and any(x['requirement'] in before and x['outcome'] != 'pass' for x in result['coverage']):
                    self.state = 'verifying'
        elif op == 'applicability.confirm':
            p['record'] = record
            self.applicability.append(p)
        elif op == 'requirement.disposition':
            p['record'] = record
            self.dispositions.append(p)
        elif op == 'issue.report':
            p.update(revision=1, resolution=None, record=record)
            self.issues[p['id']] = p
            if self.state == 'delivering':
                self.state = 'verifying'
        elif op == 'issue.resolve':
            self.issues[p['id']]['resolution'] = {'payload': p, 'record': record}
            self.issues[p['id']]['revision'] += 1
        elif op == 'block.set':
            p.update(revision=a['expected']['block'] + 1, resolved=False)
            self.blocks[p['id']] = p
        elif op == 'block.resolve':
            self.blocks[p['id']].update(resolved=True, revision=a['expected']['block'] + 1)
        elif op == 'dependency.consume':
            self.consumptions.append(p['upstream'])
            if self.candidate and self.candidates[self.candidate]['contract_revision'] == self.contract_rev:
                candidate = self.candidates[self.candidate]
                candidate['consumes'] = deepcopy(self.consumptions)
                for delivery in self.deliveries.values():
                    if delivery['target'] == {'candidate': self.candidate,
                                               'contract_revision': candidate['contract_revision']}:
                        delivery['consumes'] = deepcopy(candidate['consumes'])
        elif op == 'dependency.clearance':
            p['record'] = record
            self.clearances.append(p)
            self.deliveries[p['delivery']]['revision'] += 1
        elif op == 'delivery.record':
            # Rebuilt from immutable consume/candidate facts, including attempts
            # appended after completion. A second success is not a new root.
            consumes = self.candidates[p['target']['candidate']]['consumes']
            p.update(revision=1, reconciliations=[], consumes=deepcopy(consumes), record=record)
            self.deliveries[p['id']] = p
        elif op == 'delivery.reconcile':
            self.deliveries[p['delivery']]['revision'] += 1
            self.deliveries[p['delivery']]['reconciliations'].append(p)
        elif op == 'gate.evaluate':
            if p['gate'] == 'before-delivery' and p['advance']:
                # Only an actual successful state advance emits a task event.
                # Non-advancing assessments live in the receipt diagnostics.
                self.state = 'delivering'
        elif op == 'task.complete':
            self.state = 'done'
        elif op == 'task.cancel':
            self.state = 'canceled'

    def current(self):
        return {'contract': self.contract_rev, 'candidate_revision': self.candidate_rev,
                'candidate': self.candidate, 'owner_assignment': self.owner,
                'state': self.state, 'seq': len(self.doc['records'])}

    def delivery_inputs_known(self, delivery):
        target = delivery['target']
        contract = self.contracts.get(target['contract_revision'])
        candidate = self.candidates.get(target['candidate'])
        if contract is None or candidate is None or delivery['consumes'] != candidate['consumes']:
            return False
        required = set(contract['dependencies'] + contract['completion_children'])
        return required <= {u['task'] for u in delivery['consumes']}

    def original_result(self, rid):
        r = deepcopy(self.results[rid])
        r.pop('record', None)
        r.pop('historical_unverified', None)
        return r

    def resolved_results(self):
        out = set()
        for issue in self.issues.values():
            resolution = issue['resolution']
            if resolution:
                for rid in issue['results']:
                    if any(rid in self.results[x]['corrects'] for x in resolution['payload']['results']):
                        out.add(rid)
        return out

    def failures(self):
        closed = self.resolved_results()
        return [r for rid, r in self.results.items() if rid not in closed and
                (r['historical_unverified'] or any(x['outcome'] != 'pass' for x in r['coverage']))]

    def roots(self, delivery):
        d = self.deliveries[delivery]
        roots = []
        for r in self.failures():
            if r['target'] == d['target']:
                roots.append((self.doc['id'], 'result', r['id'], delivery))
        for issue in self.issues.values():
            if not issue['resolution'] and (delivery in issue['deliveries'] or issue['target'] == d['target']):
                roots.append((self.doc['id'], 'issue', issue['id'], delivery))
        return roots

    def assertion(self, binding, actor, role=None, target=None, requirements=None):
        item = self.assignments.get(binding['assignment'])
        require(item is not None and not item.get('revoked') and item['revision'] == binding['revision'] and
                item['identity'] == actor['identity'] and item['accepted_run'] == actor['run'],
                3, 'ASSIGNMENT', 'Current accepted assignment/run required.')
        require(role is None or item['role'] == role, 3, 'ASSIGNMENT_ROLE', 'Assignment role differs.')
        require(target is None or item['target'] == target, 3, 'ASSIGNMENT_TARGET', 'Assignment target differs.')
        require(requirements is None or set(requirements) <= set(item['requirements']),
                3, 'ASSIGNMENT_REQUIREMENTS', 'Check assignment does not cover these requirements.')
        return item
