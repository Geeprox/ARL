"""Source-only typed client atop arl/1. Does not launch or authorize inference."""
import base64
from threading import Lock
from .contracts import Fault, encode
from .research import CHUNK, DESCRIPTOR, REQUEST, READ_CHUNK, sha, strict_json, ref, FORMATS, uid, text, digest, integer, LIMITS


class PayloadCleanupPending(Fault):
    """Persist these opaque IDs and explicitly retry revoke after reconnect."""
    def __init__(self, payload_ids):
        super().__init__('payload_cleanup_pending')
        self.payload_ids = tuple(payload_ids)


class ResearchClient:
    def __init__(self, client):
        self.client = client
        self._auth_pins = {}
        self._pin_lock = Lock()

    @staticmethod
    def _cancelled(cancelled):
        if cancelled(): raise Fault('cancelled')

    def cleanup_payloads(self, payload_ids):
        # Revoke only known canonical handles through existing owner-bound RPC.
        ids = tuple(dict.fromkeys(payload_ids))
        if len(ids) > 16: raise Fault('invalid_arguments')
        for pid in ids: uid(pid)
        pending = []
        for pid in ids:
            try:
                ack = self.client.rpc('payload.revoke.v1', {'payload_id':pid})
                if type(ack) is not dict or ack != {'schema_version':1,'revoked':True,'external_stop':'unknown'} or type(ack['revoked']) is not bool or type(ack['schema_version']) is not int:
                    raise Fault('invalid_response')
            except BaseException: pending.append(pid)
        if pending: raise PayloadCleanupPending(pending) from None

    def _upload(self, raw, purpose, run_id, epoch, created, cancelled, on_payload_created):
        if type(raw) is not bytes or purpose not in {REQUEST, DESCRIPTOR}: raise Fault('invalid_arguments')
        uid(run_id); integer(epoch, 0, 2147483647); integer(len(raw), 1, LIMITS[purpose])
        self._cancelled(cancelled)
        p = self.client.rpc('payload.begin.v1', {'purpose':purpose, 'run_id':run_id,
            'epoch':epoch, 'sha256':sha(raw), 'byte_count':len(raw)})
        # Record a valid known ID even if the remaining begin response is bad.
        if type(p) is not dict or 'payload_id' not in p: raise Fault('invalid_response')
        pid = p['payload_id']; uid(pid); created.append(pid)
        record = {'owner':self.client.app,'run_id':run_id,'epoch':epoch,'purpose':purpose,
                  'payload_id':pid,'sha256':sha(raw),'byte_count':len(raw)}
        if on_payload_created is not None: on_payload_created(record)
        self._cancelled(cancelled)
        if set(p) != {'schema_version','payload_id','expires_at_ms','chunk_bytes'} or type(p['schema_version']) is not int or p['schema_version'] != 1 or type(p['chunk_bytes']) is not int or p['chunk_bytes'] != CHUNK:
            raise Fault('invalid_response')
        integer(p['expires_at_ms'], 0, 9007199254740991)
        for index, offset in enumerate(range(0,len(raw),CHUNK)):
            self._cancelled(cancelled)
            chunk = raw[offset:offset+CHUNK]
            args = {'payload_id':pid, 'index':index, 'data_base64':base64.b64encode(chunk).decode(), 'sha256':sha(chunk)}
            try: ack = self.client.rpc('payload.write.v1', args)
            except Fault as exc:
                if exc.code != 'disconnected': raise
                self._cancelled(cancelled)
                ack = self.client.rpc('payload.write.v1', args)
            self._cancelled(cancelled)
            if type(ack) is not dict or set(ack) != {'schema_version','accepted_index'} or type(ack['schema_version']) is not int or ack['schema_version'] != 1 or type(ack['accepted_index']) is not int or ack['accepted_index'] != index:
                raise Fault('invalid_response')
        value = {'payload_id':pid,'sha256':sha(raw),'byte_count':len(raw)}
        self._cancelled(cancelled)
        sealed = self.client.rpc('payload.seal.v1', value)
        self._cancelled(cancelled)
        if type(sealed) is not dict or set(sealed) != set(value)|{'schema_version'} or type(sealed['schema_version']) is not int or sealed['schema_version'] != 1 or any(sealed.get(k)!=v for k,v in value.items()):
            raise Fault('payload_binding_mismatch')
        ref({k:sealed[k] for k in value},purpose)
        return value

    def upload(self, raw, purpose, run_id, epoch, *, cancelled=lambda:False, on_payload_created=None):
        created = []
        try: return self._upload(raw,purpose,run_id,epoch,created,cancelled,on_payload_created)
        except BaseException:
            self.cleanup_payloads(created)
            raise

    def submit(self, raw, descriptor, *, epoch, provider, model_fingerprint,
               priority='explicit', deadline_ms=60000, cancelled=lambda:False, on_payload_created=None):
        created = []
        try:
            run_id = descriptor['executionID']
            request = self._upload(raw,REQUEST,run_id,epoch,created,cancelled,on_payload_created)
            metadata = self._upload(encode(descriptor),DESCRIPTOR,run_id,epoch,created,cancelled,on_payload_created)
            args = {'schema_version':1, 'run_id':run_id, 'epoch':epoch, 'request':request,
                'descriptor':metadata, 'provider':provider, 'model':descriptor['model'],
                'model_fingerprint':model_fingerprint, 'request_format':FORMATS[0],
                'output_format':FORMATS[1], 'history_version':FORMATS[2],
                'max_output_tokens':descriptor['maximumOutputTokens'], 'priority':priority, 'deadline_ms':deadline_ms}
            self._cancelled(cancelled)
            try: receipt = self.client.rpc('research.submit.v1', args)
            except Fault as exc:
                if exc.code != 'disconnected': raise
                self._cancelled(cancelled)
                receipt = self.client.rpc('research.submit.v1', args)
            self._cancelled(cancelled)
            self.check(receipt, args)
            return receipt, args
        except BaseException:
            # Includes lost submit receipts: inputs revoke the same bound run;
            # consumer must retain its uncertain run/cancel tombstone.
            self.cleanup_payloads(created)
            raise

    def check(self, receipt, args, job_id=None):
        keys = {'schema_version','job_id','owner','run_id','request_sha256','epoch','auth_epoch',
                'state','provider','model','model_fingerprint','request_format','output_format',
                'history_version','result_ref','error_code','cancel_requested','external_stop'}
        expected = {'schema_version':1, 'owner':self.client.app, 'run_id':args['run_id'],
                    'epoch':args['epoch'], 'request_sha256':args['request']['sha256'],
                    'provider':args['provider'],'model':args['model'],
                    'model_fingerprint':args['model_fingerprint'], 'request_format':args['request_format'],
                    'output_format':args['output_format'], 'history_version':args['history_version']}
        if type(receipt) is not dict or set(receipt)!=keys or any(receipt.get(k)!=v for k,v in expected.items()) or (job_id and receipt.get('job_id')!=job_id):
            raise Fault('research_receipt_mismatch')
        try:
            uid(receipt['job_id']); uid(receipt['run_id']); digest(receipt['request_sha256'])
            text(receipt['auth_epoch']); integer(receipt['schema_version'],1,1); integer(receipt['epoch'],0,2147483647)
            if receipt['state'] not in {'queued','running','succeeded','failed','cancelled','needs_unlock','needs_review'} or receipt['external_stop'] not in {'unknown','not_started'} or type(receipt['cancel_requested']) is not bool:
                raise Fault('research_receipt_mismatch')
            if receipt['error_code'] is not None: text(receipt['error_code'],100)
            if receipt['result_ref'] is not None: ref(receipt['result_ref'],'tisra.research.response.v1')
            success = receipt['state'] == 'succeeded'
            if success != (receipt['result_ref'] is not None) or (success and (receipt['cancel_requested'] or receipt['error_code'] is not None)):
                raise Fault('research_receipt_mismatch')
            if receipt['state'] in {'queued','running'} and (receipt['cancel_requested'] or receipt['error_code'] is not None):
                raise Fault('research_receipt_mismatch')
            if receipt['state'] == 'queued' and receipt['external_stop'] != 'not_started':
                raise Fault('research_receipt_mismatch')
        except (Fault, TypeError): raise Fault('research_receipt_mismatch') from None
        key = tuple(receipt[k] for k in ('owner','job_id','run_id','request_sha256','epoch'))
        with self._pin_lock:
            if self._auth_pins.setdefault(key, receipt['auth_epoch']) != receipt['auth_epoch']:
                raise Fault('research_receipt_mismatch')
        return receipt

    @staticmethod
    def binding(receipt):
        return {k:receipt[k] for k in ('job_id','run_id','request_sha256','epoch')}

    def status(self, receipt, args):
        self.check(receipt,args,receipt['job_id'])
        return self.check(self.client.rpc('research.status.v1', self.binding(receipt)), args, receipt['job_id'])

    def cancel(self, receipt, args):
        self.check(receipt,args,receipt['job_id'])
        return self.check(self.client.rpc('research.cancel.v1', self.binding(receipt)), args, receipt['job_id'])

    def read_response(self, receipt, args):
        current = self.status(receipt,args)
        if current['state']!='succeeded' or current['cancel_requested'] or not current['result_ref']:
            raise Fault('research_not_completed')
        value = current['result_ref']; ref(value,'tisra.research.response.v1')
        output = bytearray()
        while len(output)<value['byte_count']:
            chunk = self.client.rpc('payload.read.v1', {'payload_id':value['payload_id'], 'offset':len(output), 'limit':READ_CHUNK})
            if any(chunk.get(k)!=v for k,v in value.items()) or chunk.get('offset')!=len(output):
                raise Fault('payload_binding_mismatch')
            try: raw = base64.b64decode(chunk['data_base64'], validate=True)
            except (ValueError,KeyError): raise Fault('invalid_response') from None
            if not 1<=len(raw)<=READ_CHUNK or len(output)+len(raw)>value['byte_count']:
                raise Fault('invalid_response')
            output.extend(raw)
        if sha(output)!=value['sha256']: raise Fault('payload_hash_mismatch')
        # A cancellation/revoke between chunks must also invalidate this result.
        final=self.status(receipt,args)
        if final['state']!='succeeded' or final['result_ref']!=value or final['cancel_requested']:
            raise Fault('research_invalidated')
        strict_json(bytes(output))
        return bytes(output)
