"""Authorized action semantics and rebuildable gate evaluation."""
import datetime as dt
import uuid
from copy import deepcopy
from . import auth
from .codec import (Fault, canonical, dumps, evidence, now, require, sha, sources)
from .model import Model
from .store import git


def gap(code, task, message, obj=None):
    return {'code': code, 'task': task, 'object': obj, 'message': message}


def response(status, request_id=None):
    return {'kind': 'response', 'protocol': 'stage-c/2-draft', 'request_id': request_id,
            'status': status, 'exit': 0, 'durable': False, 'commit': None, 'original_commit': None,
            'gate_context': 'none', 'action_results': [], 'gates': [], 'errors': [], 'data': None}


class Engine:
    def __init__(self, store, validator, snapshot=None):
        self.store, self.validator = store, validator
        self.data = deepcopy(snapshot or store.snapshot())
        self.policy = validator.check(self.data['policy'])
        auth.policy_check(self.policy)
        self.models = {}
        self.request_order = {}
        self.rebuild()

    def rebuild(self):
        self.models = {tid: Model(doc, self.store) for tid, doc in self.data['tasks'].items()}

    def integrity(self):
        seen = set()
        for tid, model in self.models.items():
            doc = self.validator.check(model.doc)
            require(doc['id'] == tid and doc['current'] == model.current(), 11, 'CURRENT_CACHE', 'Task cache differs from immutable facts.')
            for n, r in enumerate(doc['records'], 1):
                require(r['seq'] == n and r['event_id'] not in seen, 11, 'EVENT', 'Duplicate/noncontiguous event.')
                seen.add(r['event_id'])
                self.store.policy_at(r['policy'])
                receipt = self.data['receipts'].get(r['request_id'])
                require(receipt is not None and any(x['action'] == r['action_id'] and x['task'] == tid and
                                                    r['event_id'] in x['events'] for x in receipt['action_results']),
                        11, 'RECEIPT_FACT', 'Task event lacks corresponding receipt.')
        for rid, receipt in self.data['receipts'].items():
            self.validator.check(receipt)
            require(receipt['request_id'] == rid, 11, 'RECEIPT', 'Receipt filename/ID mismatch.')
            require(all(e in seen for a in receipt['action_results'] for e in a['events']),
                    11, 'RECEIPT_FACT', 'Receipt references a missing event.')
        require(self.data['next_id'] > max(map(int, self.models), default=0),
                11, 'NEXT_ID', 'Allocator would reuse a task number.')

    def target(self, model, target, current=True):
        candidate = model.candidates.get(target['candidate'])
        require(candidate is not None and candidate['contract_revision'] == target['contract_revision'],
                2, 'CANDIDATE_REF', 'Candidate/contract reference missing or mismatched.')
        if current:
            require(model.candidate == target['candidate'] and model.contract_rev == target['contract_revision'],
                    6, 'TARGET_NOT_CURRENT', 'Current candidate/contract required.')
        return candidate

    def independent(self, model, actor, candidate, policy=None):
        runs = {r['id']: r for r in (policy or self.policy)['body']['runs']}
        require(actor['run'] in runs, 3, 'INDEPENDENCE', 'Unknown checker run.')
        for author in candidate['authors']:
            require(author['run'] in runs and actor['identity'] != author['identity'] and
                    actor['run'] != author['run'] and runs[actor['run']]['context'] != runs[author['run']]['context'],
                    3, 'INDEPENDENCE', 'Independent actual context and non-author identity required.')

    def binding(self, model, binding, actor):
        return model.assertion(binding, actor, role='owner')

    def confirm(self, actor, action, task, confirmation, allowed):
        require(confirmation['identity'] in allowed and any(confirmation['identity'] in g['confirmers']
                for g in auth.grants(self.policy, actor, action, task)),
                3, 'CONFIRMER', 'Confirmation source identity is outside delegated scope.')
        evidence(confirmation['source'])

    def artifact(self, artifact):
        from .codec import local_uri
        try:
            raw = local_uri(artifact['uri']).read_bytes()
        except OSError as exc:
            raise Fault(6, 'ARTIFACT', 'Stable artifact is not readable.') from exc
        require(sha(raw) == artifact['sha256'],
                6, 'ARTIFACT', 'Stable artifact byte hash differs.')
        if artifact['kind'] == 'git':
            require(artifact['git_object'] is not None and len(artifact['git_object']) == self.store.oid_length,
                    2, 'GIT_OBJECT', 'Full object ID for this repository hash algorithm required.')
            kind = git(self.store.root, 'cat-file', '-t', artifact['git_object'], fail=6).strip()
            require(kind in (b'blob', b'tree', b'commit'), 6, 'GIT_OBJECT', 'Unsupported object type.')
        else:
            require(artifact['git_object'] is None, 2, 'GIT_OBJECT', 'Snapshot must not pretend to be a Git object.')
        if artifact['materialization']:
            sources(artifact['materialization'])

    def requirements(self, model, revision):
        require(revision in model.contracts, 2, 'CONTRACT_REF', 'Unknown contract revision.')
        return {x['id']: x for x in model.contracts[revision]['requirements']}

    def contract_check(self, model, spec, actor, task):
        c = model.contract_value(spec)
        self.confirm(actor, 'task.open' if model.contract_rev == 0 else 'contract.revise', task,
                     spec['decision'], {x['id'] for x in self.policy['body']['identities']})
        ac = [x['id'] for x in c['acceptance']]
        reqs = {x['id']: x for x in c['requirements']}
        require(len(ac) == len(set(ac)) and len(reqs) == len(c['requirements']),
                2, 'DUPLICATE_ID', 'Acceptance/requirement IDs must be unique.')
        for r in reqs.values():
            require(set(r['acceptance']) <= set(ac) and set(r['after']) <= set(reqs),
                    2, 'REQUIREMENT_REF', 'Requirement references missing acceptance/prerequisite.')
        def visit(r, chain):
            require(r not in chain, 2, 'REQUIREMENT_CYCLE', 'Cyclic requirement ordering.')
            for pred in reqs[r]['after']:
                visit(pred, chain | {r})
        for r in reqs:
            visit(r, set())
        require(model.doc['id'] not in c['dependencies'] and len(c['dependencies']) == len(set(c['dependencies'])),
                2, 'DEPENDENCY', 'Duplicate/self dependency.')
        for child in c['completion_children']:
            require(child in self.models and self.models[child].parent == model.doc['id'],
                    2, 'PARENT', 'Completion child must be an actual child.')
            require(model.doc['id'] not in self.models[child].contract.get('dependencies', []) if self.models[child].contract else True,
                    2, 'DEPENDENCY_CYCLE', 'Child completion cannot wait for parent completion.')
        require(len(c['completion_children']) == len(set(c['completion_children'])),
                2, 'DEPENDENCY', 'Duplicate completion child.')
        def closure(tid, chain):
            require(tid not in chain, 2, 'DEPENDENCY_CYCLE', 'Completion dependency cycle.')
            other = c if tid == model.doc['id'] else self.models[tid].contract
            for upstream in (other or {}).get('dependencies', []) + (other or {}).get('completion_children', []):
                require(upstream in self.models, 2, 'DEPENDENCY_REF', 'Dependency task is missing.')
                closure(upstream, chain | {tid})
        closure(model.doc['id'], set())

    def result_ok(self, model, result, requirement, target, seen=None):
        seen = seen or set()
        if result['id'] in seen or result['historical_unverified']:
            return False
        seen = seen | {result['id']}
        coverage = {x['requirement']: x['outcome'] for x in result['coverage']}
        if coverage.get(requirement['id']) != 'pass':
            return False
        try:
            sources(result['report'])
            sources(result['environment'])
            candidate = model.candidates[result['target']['candidate']]
            if requirement['independence'] == 'independent':
                self.independent(model, result['source_actor'], candidate)
            if result['target'] != target:
                confirms = [a for a in model.applicability if a['result'] == result['id'] and
                            a['target'] == target and requirement['id'] in a['requirements'] and
                            a['decision'] == 'reuse' and not a['gaps']]
                if not confirms:
                    return False
                old = self.requirements(model, result['target']['contract_revision']).get(requirement['id'])
                if old != requirement:
                    return False
                sources(confirms[-1]['differences'])
                sources(confirms[-1]['basis'])
                if requirement['independence'] == 'independent':
                    self.independent(model, confirms[-1]['record']['actor'], model.candidates[target['candidate']])
            for predecessor in requirement['after']:
                req = self.requirements(model, target['contract_revision'])[predecessor]
                if not any(rid in model.results and self.result_ok(model, model.results[rid], req,
                           result['target'], seen) for rid in result['prerequisites']):
                    return False
            return True
        except (Fault, KeyError, OSError):
            return False

    def disposition_ok(self, model, req, target):
        for d in model.dispositions:
            if d['target'] != target or d['requirement'] != req['id']:
                continue
            if d['decision'] == 'waived' and not req['waivable']:
                continue
            if d['expires'] and (d['expires']['kind'] != 'known' or d['expires']['utc'] <= now()['utc']):
                continue
            try:
                sources(d['basis'])
                return True
            except Fault:
                continue
        return False

    def dependency_paths(self, tid, delivery, actor=None, chain=()):
        node = (tid, delivery)
        require(node not in chain, 6, 'DEPENDENCY_CYCLE', 'Dependency graph cannot be resolved.')
        if actor:
            auth.permit(self.policy, actor, 'task.read', tid, read=True)
        require(tid in self.models, 6, 'DEPENDENCY_MISSING', 'Consumed task is missing.')
        m = self.models[tid]
        require(m.state == 'done' and delivery in m.deliveries,
                6, 'DEPENDENCY_UNKNOWN', 'No successful confirmed upstream delivery.')
        d = m.deliveries[delivery]
        require(m.delivery_inputs_known(d), 6, 'DEPENDENCY_UNKNOWN',
                'Delivery consumption binding is incomplete; do not treat it as zero inputs.')
        require(d['observation'] in ('accepted', 'succeeded'), 6, 'DEPENDENCY_UNKNOWN', 'Delivery is not successful.')
        sources(d['confirmation'])
        sources(d['mapping'])
        for artifact in d['artifacts']:
            self.artifact(artifact)
        if not m.roots(delivery):
            requirements = self.requirements(m, d['target']['contract_revision'])
            require(all(self.disposition_ok(m, req, d['target']) or any(self.result_ok(m, r, req, d['target'])
                        for r in m.results.values()) for req in requirements.values()),
                    6, 'DEPENDENCY_UNKNOWN', 'Upstream evidence is unavailable or no longer applicable.')
        out = [(root, (node,)) for root in m.roots(delivery)]
        for upstream in d['consumes']:
            for origin, path in self.dependency_paths(upstream['task'], upstream['delivery'], actor, chain + (node,)):
                out.append((origin, path + (node,)))
        filtered = []
        for origin, path in out:
            if not self.cleared(m, delivery, origin):
                filtered.append((origin, path))
        return filtered

    def edge_signature(self, tid, delivery, models=None, chain=()):
        models = models or self.models
        node = (tid, delivery)
        if node in chain or tid not in models or delivery not in models[tid].deliveries:
            return None
        d = models[tid].deliveries[delivery]
        if not models[tid].delivery_inputs_known(d):
            return None
        edges = set()
        for u in d['consumes']:
            child = self.edge_signature(u['task'], u['delivery'], models, chain + (node,))
            if child is None:
                return None
            edges.add((tid, delivery, u['task'], u['delivery']))
            edges.update(child)
        return edges

    def cleared(self, model, delivery, origin):
        for clear in reversed(model.clearances):
            key = (clear['restriction_task'], clear['restriction_kind'], clear['restriction'], clear['restriction_delivery'])
            if clear['delivery'] != delivery or key != origin:
                continue
            try:
                sources(clear['basis'])
                self.clearance_witness(model, clear)
                require(all(x in model.results and all(c['outcome'] == 'pass' for c in model.results[x]['coverage'])
                            for x in clear['results']), 6, 'CLEARANCE_RESULT', 'Invalid clearance evidence.')
                base = clear['record']['policy']['commit']
                old_models = {}
                names = git(self.store.root, 'ls-tree', '-r', '--name-only', base).decode().splitlines()
                import re
                from .codec import loads
                for name in names:
                    if re.fullmatch(r'docs/tasks/(archive/)?[1-9][0-9]*\.json', name):
                        doc = loads(self.store.blob(name, base))
                        old_models[doc['id']] = Model(doc, self.store)
                # Include earlier actions of the same atomic batch, using the
                # receipt's action order; exclude later actions and later commits.
                rid = clear['record']['request_id']
                order = self.request_order.get(rid)
                if order is None:
                    receipt = self.data['receipts'].get(rid)
                    order = [a['action'] for a in receipt['action_results']] if receipt else []
                cut = order.index(clear['record']['action_id'])
                earlier = set(order[:cut])
                for tid, current in self.models.items():
                    extra = [r for r in current.doc['records'] if r['request_id'] == rid and r['action_id'] in earlier]
                    if not extra:
                        continue
                    if tid not in old_models:
                        doc = deepcopy(current.doc)
                        doc['records'] = []
                    else:
                        doc = deepcopy(old_models[tid].doc)
                    doc['records'].extend(extra)
                    old_models[tid] = Model(doc, self.store)
                if self.edge_signature(model.doc['id'], delivery, old_models) == self.edge_signature(model.doc['id'], delivery):
                    return True
            except (Fault, ValueError, KeyError, OSError):
                continue
        return False

    def clearance_witness(self, model, payload):
        from .codec import loads
        witness = loads(evidence(payload['basis']))
        require(set(witness) == {'kind', 'local', 'origin', 'edges', 'results', 'report'} and
                witness['kind'] == 'clearance-evidence' and
                witness['local'] == {'task': model.doc['id'], 'delivery': payload['delivery']} and
                witness['origin'] == {'task': payload['restriction_task'], 'kind': payload['restriction_kind'],
                                     'restriction': payload['restriction'], 'delivery': payload['restriction_delivery']} and
                set(witness['results']) == set(payload['results']),
                6, 'CLEARANCE_SCOPE', 'Clearance evidence does not bind this exact local/source version and results.')
        edges = self.edge_signature(model.doc['id'], payload['delivery'])
        require(edges is not None and len(witness['edges']) == len({tuple(x) for x in witness['edges']}) and
                {tuple(x) for x in witness['edges']} == edges,
                6, 'CLEARANCE_SCOPE', 'Revalidation must cover all known incoming consumption edges; partial/bypass evidence is insufficient.')
        evidence(witness['report'])

    def dependencies(self, model, gate, actor):
        c = model.contract
        needed = list(c['dependencies'])
        if gate == 'complete':
            needed += c['completion_children']
        consumed = model.consumptions
        for tid in set(needed):
            versions = [x for x in consumed if x['task'] == tid]
            require(versions, 6, 'DEPENDENCY_CONSUMPTION', 'Required version has not been explicitly consumed.')
            for v in versions:
                require(not self.dependency_paths(v['task'], v['delivery'], actor),
                        6, 'DEPENDENCY_RESTRICTED', 'Consumed version has unresolved restrictions.')
        # Any actual consumed input can restrict later gates, including optional children.
        if gate != 'start':
            for v in consumed:
                require(not self.dependency_paths(v['task'], v['delivery'], actor),
                        6, 'DEPENDENCY_RESTRICTED', 'Actual consumed input is restricted.')

    def gate(self, model, target, kind, actor):
        gaps = []
        try:
            require(model.contract is not None and target['contract_revision'] == model.contract_rev,
                    6, 'TARGET_NOT_CURRENT', 'Current executable contract required.')
            for b in model.blocks.values():
                require(b['resolved'] or kind not in b['gates'], 6, 'BLOCK', 'Explicit gate block remains.')
            if kind == 'start':
                binding = target['binding']
                owner = model.assignments.get(model.owner)
                require(binding and owner and binding['assignment'] == model.owner and
                        binding['revision'] == owner['revision'] and owner['accepted_run'],
                        6, 'OWNER_READY', 'Current owner assignment must be accepted.')
                auth.active(self.policy, {'identity': owner['identity'], 'run': owner['accepted_run']})
            else:
                candidate = self.target(model, target)
                for artifact in candidate['artifacts']:
                    self.artifact(artifact)
                require(not model.failures() and not any(not i['resolution'] for i in model.issues.values()),
                        6, 'UNRESOLVED', 'Failed/unknown/conflicting evidence or issue remains.')
                for requirement in model.contract['requirements']:
                    if kind == 'before-delivery' and requirement['gate'] != 'before-delivery':
                        continue
                    if kind == 'retry':
                        continue
                    ok = self.disposition_ok(model, requirement, target) or any(
                        self.result_ok(model, result, requirement, target) for result in model.results.values())
                    if not ok:
                        gaps.append(gap('CHECK_REQUIRED', model.doc['id'], 'Applicable check is missing or invalid.', requirement['id']))
                if kind in ('complete', 'retry'):
                    for d in model.deliveries.values():
                        if not d['boundary']['external']:
                            continue
                        rec = d['reconciliations'][-1] if d['reconciliations'] else None
                        if kind == 'retry' or d['observation'] in ('failed', 'unknown'):
                            require(rec and rec['actual'] == 'confirmed' and rec['retry_safe'] == 'yes',
                                    6, 'EXTERNAL_UNKNOWN', 'Previous external effects/retry safety are unresolved.')
                            sources(rec['basis'])
            self.dependencies(model, kind, actor)
        except Fault as exc:
            if exc.code == 3:
                raise
            gaps.append(gap(exc.tag, model.doc['id'], str(exc)))
        return {'task': model.doc['id'], 'candidate': None if kind == 'start' else target['candidate'],
                'gate': kind, 'outcome': 'unknown' if any(g['code'] in ('TARGET_NOT_CURRENT', 'DEPENDENCY_UNKNOWN', 'DEPENDENCY_CYCLE', 'DEPENDENCY_MISSING') for g in gaps)
                else 'blocked' if gaps else 'pass', 'gaps': gaps}

    def require_gate(self, model, target, kind, actor):
        value = self.gate(model, target, kind, actor)
        require(value['outcome'] == 'pass', 6, 'GATE', 'Gate not satisfied: ' + ','.join(x['code'] for x in value['gaps']))
        return value

    def revisions(self, model, action):
        p = action['payload']
        current = {'contract': model.contract_rev, 'candidate': model.candidate_rev}
        if 'assignment' in action['expected']:
            aid = p.get('binding', {}).get('assignment') if p.get('binding') else p.get('id')
            if action['op'] == 'gate.evaluate':
                binding = p['target']['binding']
                aid = binding['assignment'] if binding else model.owner
            current['assignment'] = model.assignments.get(aid, {}).get('revision', 0)
        if 'issue' in action['expected']:
            current['issue'] = model.issues.get(p['id'], {}).get('revision', 0)
        if 'block' in action['expected']:
            current['block'] = model.blocks.get(p['id'], {}).get('revision', 0)
        if 'delivery' in action['expected']:
            current['delivery'] = model.deliveries.get(p['delivery'], {}).get('revision', 0)
        require(all(current.get(k) == v for k, v in action['expected'].items()),
                4, 'REVISION', 'Object revision changed; reload before creating a new request.')

    def check_action(self, model, action, actor, scope):
        op, p = action['op'], action['payload']
        allowed_terminal = {'result.append', 'result.record-historical', 'issue.report', 'issue.resolve',
                            'delivery.record', 'delivery.reconcile', 'dependency.clearance', 'task.archive', 'gate.evaluate'}
        require(model.state not in ('done', 'canceled') or op in allowed_terminal,
                6, 'TERMINAL', 'Terminal history cannot be reopened; create a remediation task.')
        self.revisions(model, action)
        sources(p)
        if op in ('task.open', 'contract.revise'):
            self.contract_check(model, p['contract'], actor, scope)
            if op == 'task.open' and p.get('parent'):
                require(p['parent'] in self.models and p['parent'] != model.doc['id'], 2, 'PARENT', 'Parent must already exist.')
        elif op == 'assignment.set':
            require(any(x['id'] == p['identity'] and x['status'] == 'active' for x in self.policy['body']['identities']),
                    3, 'ASSIGNEE', 'Assignee must be an active registered identity.')
            old = model.assignments.get(p['id'])
            if p['role'] == 'owner':
                require(p['target'] is None and not p['requirements'], 2, 'OWNER_TARGET', 'Owner has no check target.')
                if model.owner:
                    require(p['isolation'] is not None, 6, 'ISOLATION', 'Confirm old run/workcopy isolation before takeover.')
            else:
                require(p['target'] is not None and p['requirements'], 2, 'CHECK_TARGET', 'Checker requires target/requirements.')
                self.target(model, p['target'], current=False)
                require(set(p['requirements']) <= set(self.requirements(model, p['target']['contract_revision'])),
                        2, 'CHECK_REF', 'Unknown check requirement.')
            require(not old or old['role'] == p['role'], 2, 'ASSIGNMENT_ROLE', 'Assignment ID cannot change role.')
        elif op == 'assignment.accept':
            item = model.assignments.get(p['binding']['assignment'])
            require(item and item['identity'] == actor['identity'] and not item.get('revoked'), 3, 'ASSIGNMENT', 'Not the current assignee.')
            require(item['accepted_run'] is None, 4, 'ASSIGNMENT_ACCEPTED', 'Use a new assignment revision for another run.')
            require(p['binding']['revision'] == item['revision'], 4, 'REVISION', 'Binding revision differs.')
        elif op in ('work.begin', 'progress.append', 'candidate.submit', 'dependency.consume'):
            self.binding(model, p['binding'], actor)
            if op == 'work.begin':
                require(model.state in ('todo', 'verifying', 'delivering'), 6, 'STATE', 'Work can only start or explicitly resume repair.')
            if op in ('work.begin', 'candidate.submit'):
                require(p['contract_revision'] == model.contract_rev, 4, 'CONTRACT', 'Contract revision differs.')
                self.require_gate(model, {'contract_revision': model.contract_rev, 'binding': p['binding']}, 'start', actor)
            if op == 'candidate.submit':
                require(model.state in ('active', 'verifying', 'delivering'), 6, 'STATE', 'Work has not begun.')
                require(p['id'] not in model.candidates, 5, 'ID_REUSE', 'Candidate ID is immutable.')
                require(actor in p['authors'], 3, 'AUTHOR', 'Actual submitting author must be declared.')
                for artifact in p['artifacts']:
                    self.artifact(artifact)
                ac = {x['id'] for x in model.contract['acceptance']}
                require({x['acceptance'] for x in p['acceptance_mapping']} == ac and
                        len(p['acceptance_mapping']) == len(ac), 2, 'AC_MAPPING', 'Every acceptance ID must map exactly once.')
                aids = [x['id'] for x in p['artifacts']]
                require(len(aids) == len(set(aids)) and all(set(x['artifacts']) <= set(aids) for x in p['acceptance_mapping']),
                        2, 'ARTIFACT_REF', 'Invalid/duplicate artifact reference.')
                require({i for i, x in model.issues.items() if not x['resolution']} <= set(p['known_issues']),
                        6, 'KNOWN_ISSUES', 'Disclose unresolved issues; candidate changes do not close them.')
            if op == 'dependency.consume':
                upstream = p['upstream']
                require(upstream['task'] in model.contract['dependencies'] + model.contract['completion_children'],
                        2, 'DEPENDENCY_SCOPE', 'Consumption is not in the approved contract.')
                require(not self.dependency_paths(upstream['task'], upstream['delivery'], actor), 6, 'DEPENDENCY_RESTRICTED', 'Upstream delivery is restricted.')
        elif op in ('result.append', 'result.record-historical'):
            r = p if op == 'result.append' else p['result']
            candidate = self.target(model, r['target'], current=False)
            requirements = self.requirements(model, r['target']['contract_revision'])
            require(len({x['requirement'] for x in r['coverage']}) == len(r['coverage']) and
                    all(x['requirement'] in requirements for x in r['coverage']), 2, 'COVERAGE', 'Unknown/duplicate check coverage.')
            coverage = [x['requirement'] for x in r['coverage']]
            independent = any(requirements[x]['independence'] == 'independent' for x in coverage)
            if op == 'result.append':
                require(r['source_actor'] == actor, 3, 'SOURCE_ACTOR', 'Direct results require actual current actor.')
                if independent:
                    model.assertion(r['binding'], actor, 'checker', r['target'], coverage)
                    self.independent(model, actor, candidate)
                else:
                    self.binding(model, r['binding'], actor)
            else:
                binding = r['binding']
                old_assignment = model.assignments.get(binding['assignment'])
                if old_assignment is None or old_assignment['revision'] != binding['revision']:
                    old_assignment = model.assignment_history.get((binding['assignment'], binding['revision']))
                require(old_assignment is not None and old_assignment['identity'] == r['source_actor']['identity'] and
                        old_assignment['accepted_run'] == r['source_actor']['run'],
                        6, 'HISTORICAL_SOURCE', 'Original accepted assignment/run cannot be verified.')
                accepts = [event for event in model.doc['records'] if event['action']['op'] == 'assignment.accept' and
                           event['action']['payload']['binding'] == binding and event['actor'] == r['source_actor']]
                require(accepts, 6, 'HISTORICAL_SOURCE', 'Original acceptance fact is missing.')
                original_policy = self.store.policy_at(accepts[-1]['policy'])
                auth.active(original_policy, r['source_actor'])
                auth.permit(original_policy, r['source_actor'], 'result.append', model.doc['id'])
                require(old_assignment['role'] == ('checker' if independent else 'owner'),
                        3, 'ASSIGNMENT_ROLE', 'Original assignment role does not qualify this result.')
                if independent:
                    require(old_assignment['target'] == r['target'],
                            3, 'ASSIGNMENT_TARGET', 'Original assignment target differs.')
                    require(set(coverage) <= set(old_assignment['requirements']),
                            3, 'ASSIGNMENT_REQUIREMENTS', 'Original assignment does not cover these requirements.')
                    self.independent(model, r['source_actor'], candidate, original_policy)
            if r['id'] in model.results:
                require(canonical(model.original_result(r['id'])) == canonical(r), 5, 'RESULT_REUSE', 'Result ID cannot be overwritten.')
                return False, None
            require(all(x in model.results for x in r['corrects']), 2, 'CORRECTION_REF', 'Corrected result is missing.')
        elif op == 'applicability.confirm':
            candidate = self.target(model, p['target'])
            require(p['result'] in model.results, 2, 'RESULT_REF', 'Original result missing.')
            requirements = self.requirements(model, p['target']['contract_revision'])
            require(set(p['requirements']) <= set(requirements), 2, 'CHECK_REF', 'Unknown target requirement.')
            if any(requirements[x]['independence'] == 'independent' for x in p['requirements']):
                model.assertion(p['binding'], actor, 'checker', p['target'], p['requirements'])
                self.independent(model, actor, candidate)
            else:
                self.binding(model, p['binding'], actor)
            require(p['id'] not in {x['id'] for x in model.applicability}, 5, 'ID_REUSE', 'Applicability ID is immutable.')
        elif op == 'requirement.disposition':
            self.target(model, p['target'])
            r = self.requirements(model, p['target']['contract_revision']).get(p['requirement'])
            require(r is not None and (p['decision'] != 'waived' or r['waivable']), 6, 'DISPOSITION', 'Requirement cannot be waived.')
            self.confirm(actor, op, scope, p['basis'], {x['id'] for x in self.policy['body']['identities']})
            require(p['id'] not in {x['id'] for x in model.dispositions}, 5, 'ID_REUSE', 'Disposition ID is immutable.')
        elif op == 'issue.report':
            self.target(model, p['target'], current=False)
            require(p['id'] not in model.issues, 5, 'ID_REUSE', 'Issue ID is immutable.')
            require(set(p['results']) <= set(model.results) and set(p['deliveries']) <= set(model.deliveries),
                    2, 'ISSUE_REF', 'Issue ID or affected references are invalid.')
            require(all(model.deliveries[x]['target'] == p['target'] for x in p['deliveries']),
                    2, 'ISSUE_TARGET', 'Source issue must actually affect each named delivery.')
        elif op == 'issue.resolve':
            require(p['id'] in model.issues and set(p['results']) <= set(model.results), 2, 'ISSUE_REF', 'Issue/result missing.')
            issue = model.issues[p['id']]
            require(not issue['resolution'], 6, 'ISSUE_CLOSED', 'Issue already resolved.')
            old_req = self.requirements(model, issue['target']['contract_revision'])
            independent = any(old_req[x['requirement']]['independence'] == 'independent'
                              for rid in issue['results'] for x in model.results[rid]['coverage'])
            if independent or not issue['results']:
                self.independent(model, actor, model.candidates[issue['target']['candidate']])
            require(all(all(x['outcome'] == 'pass' for x in model.results[r]['coverage']) for r in p['results']),
                    6, 'RESOLUTION', 'Qualified passing revalidation is required.')
            affected = {x['requirement'] for rid in issue['results'] for x in model.results[rid]['coverage']}
            affected = affected or set(old_req)
            for reqid in affected:
                require(any(reqid in self.requirements(model, model.results[rid]['target']['contract_revision']) and
                            self.requirements(model, model.results[rid]['target']['contract_revision'])[reqid] == old_req[reqid] and
                            self.result_ok(model, model.results[rid], old_req[reqid], model.results[rid]['target'])
                            for rid in p['results']), 6, 'RESOLUTION', 'Revalidation must cover the affected requirement with qualified evidence.')
            if p['decision'] == 'accepted-risk':
                require(all(old_req[x]['waivable'] and self.disposition_ok(model, old_req[x], issue['target']) for x in affected),
                        6, 'RESOLUTION', 'Risk acceptance cannot bypass nonwaivable requirements.')
        elif op == 'block.resolve':
            require(p['id'] in model.blocks and not model.blocks[p['id']]['resolved'], 6, 'BLOCK', 'Active block missing.')
        elif op == 'dependency.clearance':
            require(p['delivery'] in model.deliveries, 2, 'DELIVERY_REF', 'Local delivery missing.')
            origin = (p['restriction_task'], p['restriction_kind'], p['restriction'], p['restriction_delivery'])
            require(p['restriction_task'] in self.models, 2, 'ORIGIN', 'Source task missing.')
            source = self.models[p['restriction_task']]
            require(p['restriction_delivery'] in source.deliveries and origin in source.roots(p['restriction_delivery']),
                    2, 'ORIGIN', 'Source entity does not restrict that source delivery.')
            current = model.deliveries[p['delivery']]
            reachable = []
            for u in current['consumes']:
                reachable += self.dependency_paths(u['task'], u['delivery'], actor)
            require(any(key == origin for key, _ in reachable), 2, 'ORIGIN_PATH', 'Source cannot reach this delivery.')
            self.independent(model, actor, model.candidates[current['target']['candidate']])
            require(p['id'] not in {x['id'] for x in model.clearances} and p['results'] and
                    all(r in model.results and model.results[r]['target'] == current['target'] and
                        all(c['outcome'] == 'pass' and self.result_ok(model, model.results[r],
                            self.requirements(model, current['target']['contract_revision'])[c['requirement']], current['target'])
                            for c in model.results[r]['coverage']) for r in p['results']),
                    6, 'CLEARANCE_RESULT', 'Qualified version-specific revalidation is required.')
            require(any(a['role'] == 'checker' and a['identity'] == actor['identity'] and
                        a['accepted_run'] == actor['run'] and not a.get('revoked') and a['target'] == current['target']
                        for a in model.assignments.values()), 3, 'ASSIGNMENT', 'Clearance requires an accepted checker assignment for this version.')
            self.clearance_witness(model, p)
        elif op == 'delivery.record':
            self.target(model, p['target'], current=False)
            c = model.contracts[p['target']['contract_revision']]
            require(p['id'] not in model.deliveries, 5, 'ID_REUSE', 'Every delivery attempt has a new ID.')
            require(p['boundary'] == c['boundary'], 2, 'BOUNDARY', 'Record the approved actual boundary.')
            self.confirm(actor, op, scope, p['confirmation'], set(c['boundary']['confirmers']))
            require(p['previous_attempt'] is None or p['previous_attempt'] in model.deliveries,
                    2, 'ATTEMPT_REF', 'Previous attempt missing.')
            for artifact in p['artifacts']:
                self.artifact(artifact)
        elif op == 'delivery.reconcile':
            require(p['delivery'] in model.deliveries, 2, 'DELIVERY_REF', 'Attempt missing.')
            d = model.deliveries[p['delivery']]
            self.confirm(actor, op, scope, p['basis'], {d['responsible']} | set(d['boundary']['confirmers']))
            require(p['actual'] != 'confirmed' or p['version'] is not None, 2, 'ACTUAL_VERSION', 'Confirmed version evidence required.')
        elif op == 'gate.evaluate':
            if p['gate'] == 'start':
                require(p['target']['contract_revision'] == model.contract_rev, 4, 'REVISION', 'Start contract changed.')
                b = p['target']['binding']
                require((b is None and model.owner is None and action['expected']['assignment'] == 0) or
                        (b is not None and b['assignment'] == model.owner and b['revision'] == action['expected']['assignment']),
                        4, 'REVISION', 'Start owner binding changed.')
            else:
                self.target(model, p['target'])
            assessed = self.gate(model, p['target'], p['gate'], actor)
            advancing = p['advance'] and assessed['outcome'] == 'pass'
            if advancing:
                require(model.state == 'verifying', 6, 'STATE', 'Only verifying tasks advance to delivering.')
            return advancing, assessed
        elif op == 'task.complete':
            require(model.state == 'delivering' and p['delivery'] in model.deliveries, 6, 'STATE', 'Actual delivery and delivering state required.')
            require(model.deliveries[p['delivery']]['target'] == p['target'] and
                    model.deliveries[p['delivery']]['observation'] in ('accepted', 'succeeded'),
                    6, 'ACCEPTANCE', 'Actual accepted delivery of this candidate required.')
            delivery = model.deliveries[p['delivery']]
            sources(delivery['mapping'])
            sources(delivery['confirmation'])
            for artifact in delivery['artifacts']:
                self.artifact(artifact)
            self.require_gate(model, p['target'], 'before-delivery', actor)
            self.require_gate(model, p['target'], 'complete', actor)
        elif op == 'task.archive':
            require(model.state in ('done', 'canceled'), 6, 'ARCHIVE', 'Only terminal tasks can be archived.')
        return True, None

    def apply(self, request):
        self.validator.check(request)
        actor, rid = request['actor'], request['request_id']
        auth.active(self.policy, actor)
        old = self.data['receipts'].get(rid)
        if old:
            auth.receipt_scope(self.policy, actor, old)
            require(old['request_hash'] == sha(canonical(request)), 5, 'REQUEST_REUSE', 'Same request ID has different canonical content.')
            out = response('replayed', rid)
            out.update(durable=True, original_commit=self.receipt_commit(rid), gate_context='historical',
                       action_results=old['action_results'], gates=old['gates'])
            return out, None
        self.integrity()
        actions = request['actions']
        require(len({a['id'] for a in actions}) == len(actions), 2, 'ACTION_ID', 'Action IDs must be unique.')
        policy_actions = [a for a in actions if a['op'] == 'policy.update']
        require(not policy_actions or len(actions) == 1, 2, 'POLICY_BATCH', 'Policy updates are exclusive transactions.')
        require(sum(a['op'] == 'task.open' for a in actions) <= 1, 2, 'NEW_TASK', 'At most one new task per batch.')
        self.request_order[rid] = [a['id'] for a in actions]
        result, alias = response('committed', rid), None
        for action in actions:
            p, op, original = action['payload'], action['op'], action['task']
            if op == 'policy.update':
                require(original == 'policy', 2, 'POLICY_TARGET', 'Policy action requires policy target.')
                auth.permit(self.policy, actor, op, '*')
                require(action['expected']['policy'] == self.policy['revision'], 4, 'REVISION', 'Policy changed.')
                sources(p)
                self.confirm(actor, op, '*', p['decision'], {x['id'] for x in self.policy['body']['identities']})
                new_policy = {'kind': 'policy', 'protocol': 'stage-c/2-draft', 'revision': self.policy['revision'] + 1,
                              'body': p['replacement'], 'decision': p['decision']}
                self.validator.check(new_policy)
                auth.policy_check(new_policy)
                for collection in ('identities', 'runs'):
                    old_entries = {x['id']: x for x in self.policy['body'][collection]}
                    new_entries = {x['id']: x for x in new_policy['body'][collection]}
                    require(set(old_entries) <= set(new_entries), 2, 'IDENTITY_HISTORY', 'Revoke identities/runs instead of deleting history.')
                    if collection == 'runs':
                        require(all(new_entries[k]['identity'] == v['identity'] and new_entries[k]['context'] == v['context']
                                    for k, v in old_entries.items()), 2, 'RUN_REUSE', 'A run ID cannot change identity or actual context.')
                self.data['policy'] = new_policy
                result['action_results'].append({'action': action['id'], 'task': None, 'events': [], 'disposition': 'current'})
                continue
            require(original != 'policy', 2, 'TARGET', 'Task action cannot target policy.')
            auth.permit(self.policy, actor, op, original)
            if op == 'task.open':
                require(original == 'new' and alias is None and self.data['next_id'] <= 999999999999999,
                        2, 'NEW_TASK', 'Creation requires a fresh allocated new alias.')
                alias = str(self.data['next_id'])
                self.data['next_id'] += 1
                self.data['tasks'][alias] = {'kind': 'task', 'protocol': 'stage-c/2-draft', 'id': alias,
                    'title': p['title'], 'legacy': None, 'records': [], 'current': {'contract': 0, 'candidate_revision': 0,
                    'candidate': None, 'owner_assignment': None, 'state': 'todo', 'seq': 0}}
                self.data['paths'][alias] = 'docs/tasks/' + alias + '.json'
                self.rebuild()
            tid = alias if original == 'new' else original
            require(tid is not None and tid in self.models, 2, 'TASK_REF', 'Task/new alias is not available.')
            model = self.models[tid]
            mutate, assessed = self.check_action(model, action, actor, original)
            events = []
            if assessed:
                result['gates'].append(assessed)
            if mutate:
                event = {'seq': len(model.doc['records']) + 1, 'event_id': str(uuid.uuid4()), 'request_id': rid,
                         'action_id': action['id'], 'actor': actor, 'policy': self.store.policy_ref(self.data['commit']),
                         'recorded_at': now(), 'action': deepcopy(action)}
                model.doc['records'].append(event)
                events = [event['event_id']]
                self.rebuild()
                model = self.models[tid]
                model.doc['current'] = model.current()
                if op == 'task.archive':
                    self.data['paths'][tid] = 'docs/tasks/archive/' + tid + '.json'
            historical = op == 'result.record-historical' or (op == 'result.append' and p['target']['candidate'] != model.candidate)
            result['action_results'].append({'action': action['id'], 'task': tid, 'events': events,
                'disposition': 'evaluated' if assessed else 'historical' if historical else 'current'})
        receipt = {'kind': 'receipt', 'protocol': 'stage-c/2-draft', 'request_id': rid,
                   'request_hash': sha(canonical(request)), 'actor': actor, 'recorded_at': now(),
                   'action_results': result['action_results'], 'gates': result['gates']}
        self.data['receipts'][rid] = receipt
        self.integrity()
        result.update(durable=True, gate_context='at-commit')
        return result, receipt

    def receipt_commit(self, rid):
        raw = git(self.store.root, 'log', '--format=%H', '--diff-filter=A', '--', '.task-center/receipts/' + rid + '.json')
        require(raw.strip(), 11, 'RECEIPT_HISTORY', 'Receipt creation commit missing.')
        return raw.decode().splitlines()[-1]

    def changes(self, before, receipt):
        changes = {'.task-center/policy.json': dumps(self.data['policy']),
                   '.task-center/next-id': (str(self.data['next_id']) + '\n').encode(),
                   '.task-center/receipts/' + receipt['request_id'] + '.json': dumps(receipt)}
        for tid, doc in self.data['tasks'].items():
            path = self.data['paths'][tid]
            changes[path] = dumps(doc)
            old = before['paths'].get(tid)
            if old and old != path:
                changes[old] = None
        rows = ['# Task index', '', '> Generated read-only view. Task JSON is authoritative.', '', '| ID | Title | State |', '|---|---|---|']
        for tid, m in sorted(self.models.items(), key=lambda x: int(x[0])):
            title = m.doc['title'].replace('|', '\\|').replace('\n', ' ')
            rows.append('| ' + tid + ' | ' + title + ' | ' + m.state + ' |')
        changes['docs/tasks/INDEX.md'] = ('\n'.join(rows) + '\n').encode('utf-8')
        return {p: raw for p, raw in changes.items() if self.store.blob(p, before['commit']) != raw}

    def query(self, query):
        self.validator.check(query)
        actor, op = query['actor'], query['op']
        auth.active(self.policy, actor)
        out = response('read')
        out['commit'] = self.data['commit']
        if op == 'policy.read':
            auth.permit(self.policy, actor, op, '*', read=True)
            out['data'] = {'op': op, 'policy': self.policy}
        elif op == 'task.list':
            eligible = any(g['identity'] == actor['identity'] and op in g['read_actions'] and
                           any(t != 'new' for t in g['tasks']) for g in self.policy['body']['grants'])
            require(eligible, 3, 'READ_SCOPE_DENIED', 'No list scope.')
            tasks = [{'id': tid, 'title': m.doc['title'], 'state': m.state, 'candidate': m.candidate}
                     for tid, m in sorted(self.models.items(), key=lambda x: int(x[0])) if auth.allowed(self.policy, actor, op, tid, True)]
            out['data'] = {'op': op, 'tasks': tasks}
        elif op == 'receipt.read':
            rid = query['receipt_id']
            receipt = self.data['receipts'].get(rid)
            if receipt is None:
                auth.permit(self.policy, actor, op, '*', True)
                raise Fault(2, 'NOT_FOUND', 'Receipt not found in readable scope.')
            auth.receipt_scope(self.policy, actor, receipt)
            out.update(original_commit=self.receipt_commit(rid), gate_context='historical')
            out['data'] = {'op': op, 'receipt': receipt}
        else:
            tid = query['task']
            auth.permit(self.policy, actor, op, tid, True)
            require(tid in self.models, 2, 'NOT_FOUND', 'Readable root task is missing.')
            model = self.models[tid]
            if op in ('task.check', 'task.handoff', 'gate.read'):
                def scope(mid, seen):
                    require(mid in self.models, 6, 'DEPENDENCY_MISSING', 'Related task missing.')
                    if mid in seen:
                        return
                    m = self.models[mid]
                    for dep in set((m.contract or {}).get('dependencies', []) + (m.contract or {}).get('completion_children', []) + [x['task'] for x in m.consumptions]):
                        auth.permit(self.policy, actor, 'task.read', dep, True)
                        if dep in self.models:
                            scope(dep, seen | {mid})
                scope(tid, set())
            if op == 'task.read':
                out['data'] = {'op': op, 'task': model.doc}
            elif op == 'gate.read':
                p = query['payload']
                out['gates'] = [self.gate(model, p['target'], p['gate'], actor)]
                out.update(gate_context='current-read', data={'op': op})
            elif op == 'task.handoff':
                text = '# ' + tid + ': ' + model.doc['title'] + '\n\nState: ' + model.state + '\n'
                text += 'Contract: ' + str(model.contract_rev) + '; candidate: ' + str(model.candidate) + '\n'
                if model.contract:
                    text += '\nGoal: ' + model.contract['goal'] + '\nAcceptance:\n'
                    text += ''.join('- ' + ac['id'] + ': ' + ac['text'] + '\n' for ac in model.contract['acceptance'])
                    text += 'Write scope: ' + '; '.join(model.contract['write_scope']) + '\n'
                    text += 'Delivery boundary: ' + model.contract['boundary']['description'] + '\n'
                if model.candidate:
                    candidate = model.candidates[model.candidate]
                    text += '\nPinned artifacts:\n' + ''.join('- ' + a['uri'] + ' sha256=' + a['sha256'] + '\n' for a in candidate['artifacts'])
                    text += '\nOriginal reports (check object, method, environment and uncovered scope):\n'
                    text += ''.join('- ' + r['id'] + ' [' + r['target']['candidate'] + '] ' + r['report']['uri'] +
                                    ' sha256=' + r['report']['sha256'] + '\n' for r in model.results.values())
                text += '\nOpen issues: ' + ', '.join(i for i, v in model.issues.items() if not v['resolution']) + '\n'
                text += 'No acceptance, external action, or independent check is implied by this generated view.\n'
                out['data'] = {'op': op, 'task': tid, 'text': text}
            else:
                gaps = []
                try:
                    self.integrity()
                except Fault as exc:
                    gaps.append(gap(exc.tag, tid, str(exc)))
                out['data'] = {'op': op, 'task': tid, 'consistent': not gaps, 'gaps': gaps,
                               'readiness': [] if model.contract else [gap('CONTRACT_REQUIRED', tid, 'Modern contract is missing.')]}
        self.validator.check(out)
        return out
