"""Explicit action/read scopes; declarations are not strong authentication."""
from .codec import require


def active(policy, actor):
    body = policy['body']
    person = next((x for x in body['identities'] if x['id'] == actor['identity']), None)
    run = next((x for x in body['runs'] if x['id'] == actor['run']), None)
    require(person is not None and person['status'] == 'active' and run is not None and
            run['status'] == 'active' and run['identity'] == actor['identity'],
            3, 'ACTOR', 'Identity/run is unknown, revoked or mismatched.')


def grants(policy, actor, action, task, read=False):
    key = 'read_actions' if read else 'actions'
    return [g for g in policy['body']['grants'] if g['identity'] == actor['identity'] and
            action in g[key] and (task in g['tasks'] or '*' in g['tasks'])]


def allowed(policy, actor, action, task, read=False):
    return bool(grants(policy, actor, action, task, read))


def permit(policy, actor, action, task, read=False):
    require(allowed(policy, actor, action, task, read), 3,
            'READ_SCOPE_DENIED' if read else 'ACTION_DENIED', 'Required scope is not authorized.')


def receipt_scope(policy, actor, receipt):
    active(policy, actor)
    for result in receipt['action_results']:
        task = result['task']
        permit(policy, actor, 'receipt.read', task or '*', read=True)
        if task is None:
            permit(policy, actor, 'policy.read', '*', read=True)


def policy_check(policy):
    body = policy['body']
    for name in ('identities', 'runs', 'grants', 'defaults'):
        ids = [x['id'] for x in body[name]]
        require(len(ids) == len(set(ids)), 2, 'DUPLICATE_ID', 'Duplicate policy entity.')
    people = {x['id'] for x in body['identities']}
    for run in body['runs']:
        require(run['identity'] in people, 2, 'IDENTITY_REF', 'Run identity is missing.')
    for grant in body['grants']:
        require(grant['identity'] in people and set(grant['confirmers']) <= people,
                2, 'IDENTITY_REF', 'Grant references an unknown identity.')
        for key in ('actions', 'read_actions', 'tasks', 'confirmers'):
            require(len(grant[key]) == len(set(grant[key])), 2, 'DUPLICATE', 'Duplicate grant value.')
    for profile in body['defaults']:
        require(profile['coordinator'] in people and set(profile['boundary']['confirmers']) <= people,
                2, 'IDENTITY_REF', 'Profile references an unknown identity.')
