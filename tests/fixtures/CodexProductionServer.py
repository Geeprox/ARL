"""Synthetic stdio provider. Never reads accounts or performs network IO."""
import json
import sys
import uuid


def emit(value):
    print(json.dumps(value), flush=True)


thread = None
thread_id = 'synthetic-thread-'+str(uuid.uuid4())
turn_id = 'synthetic-turn-'+str(uuid.uuid4())
for line in sys.stdin:
    message = json.loads(line)
    method, params, key = message.get('method'), message.get('params', {}), message.get('id')
    if method == 'initialize':
        emit({'id': key, 'result': {}})
    elif method == 'model/list':
        emit({'id': key, 'result': {'data': [{'model': 'synthetic-model', 'displayName': 'Synthetic',
            'description': 'Offline fixture', 'hidden': False, 'defaultReasoningEffort': 'medium',
            'supportedReasoningEfforts': [{'reasoningEffort': e, 'description': e}
                for e in ('low', 'medium', 'high', 'xhigh', 'max')], 'serviceTiers': []}], 'nextCursor': None}})
    elif method == 'thread/start':
        thread = params
        assert params['serviceTier'] == 'default'
        emit({'id': key, 'result': {'model': params['model'], 'thread': {'id': thread_id, 'ephemeral': True},
            'reasoningEffort': params['config']['model_reasoning_effort'], 'serviceTier': params['serviceTier']}})
    elif method == 'turn/start':
        assert thread and params['effort'] == thread['config']['model_reasoning_effort']
        assert params['serviceTierForTurn'] == thread['serviceTier']
        emit({'id': key, 'result': {'turn': {'id': turn_id, 'status': 'inProgress'}}})
        if params['input'][0]['text'].startswith('List every integer'):
            continue
        emit({'method': 'item/completed', 'params': {'threadId': thread_id, 'turnId': turn_id,
            'item': {'type': 'agentMessage', 'text': json.dumps({'text': 'ARL_CODEX_OK'})}}})
        emit({'method': 'turn/completed', 'params': {'threadId': thread_id,
            'turn': {'id': turn_id, 'status': 'completed'}}})
    elif method == 'turn/interrupt':
        assert params == {'threadId': thread_id, 'turnId': turn_id}
        emit({'id': key, 'result': {}})
        emit({'method': 'turn/completed', 'params': {'threadId': thread_id,
            'turn': {'id': turn_id, 'status': 'interrupted'}}})
