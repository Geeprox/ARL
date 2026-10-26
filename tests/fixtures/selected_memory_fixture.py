import copy,json,types
from arl.contracts import encode
from arl.research import sha
from arl import codex_sourced_contract as sourced
RUN='11111111-1111-4111-8111-111111111111'
JOB='22222222-2222-4222-8222-222222222222'
SNAP='33333333-3333-4333-8333-333333333333'
RECORDS=['44444444-4444-4444-8444-444444444444','55555555-5555-4555-8555-555555555555']
MODEL='synthetic-selected-model'
def source(record, text='完整正文。中文 café 😀 exact evidence.'):
    return {'evidence_id': SNAP, 'snapshot_digest': sha(b'complete snapshot'),
            'record_id': record, 'revision': 1, 'unit': None, 'attachment_sha256': None,
            'text': text, 'title': 'Selected record', 'locator': None, 'extraction_state': 'ready'}

def request():
    return {'schema_version': 1, 'query': 'Compare the complete selected records.',
            'scope': {'scope_id': RUN, 'scope_revision': 0}, 'candidate_origin': 'manual_selection',
            'candidates': [{'candidate_id': identity, 'parts': [source(identity)]} for identity in RECORDS]}

def quote(part, text='中文 café 😀'):
    start = part['text'].encode().index(text.encode())
    return dict({key: part[key] for key in sourced.EVIDENCE_KEYS}, quote=text,
                start_utf8=start, end_utf8=start + len(text.encode()))

def ranking(obj):
    return {'schema_version': 1, 'ranked_candidates': [
        {'candidate_id': c['candidate_id'], 'reason': 'Reason grounded in this candidate.',
         'citations': [quote(c['parts'][0])]} for c in reversed(obj['candidates'])]}

def explanation():
    return {'schema_version': 2, 'text': 'Explain these complete records.', 'public_history': [],
            'evidence': [source(x) for x in RECORDS], 'migration': None}

class MemorySession:
    instances = []
    body = None
    event_mode = None

    def __init__(self, binary, workspace, **kwargs):
        self.context = kwargs['context']; self.thread_id = self.turn_id = None
        self.process = types.SimpleNamespace(returncode=0)
        self.messages = []; self.requests = []; self.next_id = 0; self.closed = False; self.interrupts = 0
        self.__class__.instances.append(self)

    def initialize(self):
        self.context.check_cancelled()

    def send(self, method, params):
        self.next_id += 1; self.requests.append((method, copy.deepcopy(params)))
        if method == 'turn/start':
            body = self.__class__.body
            if callable(body): body = body(params['input'][0]['text'])
            self.messages = [
                {'id': self.next_id, 'result': {'turn': {'id': 'turn-fixture', 'status': 'inProgress'}}},
                {'method': 'item/completed', 'params': {'threadId': 'thread-fixture', 'turnId': 'turn-fixture',
                    'item': {'type': 'userMessage', 'content': params['input']}}},
                {'method': 'item/completed', 'params': {'threadId': 'thread-fixture', 'turnId': 'turn-fixture',
                    'item': {'type': 'agentMessage', 'text': encode(body).decode()}}},
                {'method': 'turn/completed', 'params': {'threadId': 'thread-fixture',
                    'turn': {'id': 'turn-fixture', 'status': 'completed'}}}]
            if self.__class__.event_mode == 'wrong_thread':
                self.messages[2]['params']['threadId'] = 'wrong-thread'
            if self.__class__.event_mode == 'tool':
                self.messages[2]['params']['item'] = {'type': 'webSearch'}
        return self.next_id

    def response(self, identifier):
        method, params = self.requests[-1]
        assert method == 'thread/start'
        return {'model': params['model'], 'thread': {'id': 'thread-fixture', 'ephemeral': True}}

    def receive(self):
        self.context.check_cancelled()
        message = self.messages.pop(0)
        if self.__class__.event_mode == 'binding_drift' and message.get('method') == 'turn/completed':
            self.context.base.binding['epoch'] += 1
        return message

    def cancel_turn(self):
        self.interrupts += 1

    def close(self):
        self.closed = True
