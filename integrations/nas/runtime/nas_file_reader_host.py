"""Compose recursive names/UTF8 with the existing live private NAS host only."""
import re
import time
from homeplane.nas_connection.contracts import NASConnectionError
from homeplane.nas_connection.file_search import ScopedFileReader

OPERATIONS=frozenset({'search_recursive','read_text','read_document'})
FENCE={'source_ref','config_generation','connection_epoch'}


def request(value):
    if type(value) is not dict or value.get('operation') not in OPERATIONS:
        raise NASConnectionError('nas_invalid_request')
    if value['operation']=='read_document':
        from nas_document_host import request as document_request
        return document_request(value)
    operation=value['operation']; base=FENCE|{'operation'}
    required=base|({'keyword','recursive'} if operation=='search_recursive' else {'object_ref','revision','size'})
    allowed=required|({'directory_ref','cursor','limit'} if operation=='search_recursive' else {'max_bytes','offset'})
    if not required<=set(value)<=allowed:
        raise NASConnectionError('nas_invalid_request')
    def hex64(v,n):return type(v) is str and len(v)==n and re.fullmatch('[0-9a-f]+',v) is not None
    if (type(value['source_ref']) is not str or re.fullmatch('[A-Za-z0-9_-]{1,96}',value['source_ref']) is None
            or type(value['config_generation']) is not int or not 1<=value['config_generation']<=2**63-1
            or not hex64(value['connection_epoch'],32)):
        raise NASConnectionError('nas_invalid_request')
    result=dict(value)
    if operation=='search_recursive':
        from homeplane.nas_connection.contracts import file_request
        if value['recursive'] is not True:raise NASConnectionError('nas_invalid_request')
        selected={k:value[k] for k in ('keyword','directory_ref','cursor','limit') if k in value}
        selected.setdefault('limit',32)
        file_request(dict(selected,operation='search'))
        result.update(selected)
    else:
        if (not hex64(value['object_ref'],64) or not hex64(value['revision'],64)
                or type(value['size']) is not int or not 0<=value['size']<=2**63-1
                or type(value.get('max_bytes',65536)) is not int or not 1<=value.get('max_bytes',65536)<=65536):
            raise NASConnectionError('nas_invalid_request')
        result.setdefault('max_bytes',65536)
        if type(value.get('offset',0)) is not int or not 0<=value.get('offset',0)<=value['size']:
            raise NASConnectionError('nas_invalid_request')
        result.setdefault('offset',0)
    return result


async def execute(host, value):
    value=request(value)
    connection,authority=host.connection,host.authority
    if connection is None or authority is None:raise NASConnectionError('nas_unavailable')
    manager=connection.manager
    fence=(value['source_ref'],value['config_generation'],value['connection_epoch'])
    async def validate(source,generation,epoch):
        if (host.connection is not connection or host.authority is not authority or authority.revoked
                or time.monotonic()>=authority.deadline):
            raise NASConnectionError('nas_source_changed')
        await connection.credentials.check('request')
        if (host.connection is not connection or host.authority is not authority or authority.revoked
                or manager.config is None or manager.config.source_ref!=source
                or manager._source(source)!=(generation,epoch)):
            raise NASConnectionError('nas_source_changed')
        return True
    await validate(*fence)
    reader=getattr(host,'file_reader',None)
    if reader is None:
        reader=ScopedFileReader(source_ref=fence[0],config_generation=fence[1],connection_epoch=fence[2],
            operation=manager.file_operation,validate_context=validate)
        host.file_reader=reader
    elif reader.fence!=fence:
        raise NASConnectionError('nas_source_changed')
    if value['operation']=='read_document':
        from nas_document_host import execute as document_execute
        return await document_execute(host,value,reader,lambda:validate(*fence))
    if value['operation']=='search_recursive':
        selected={k:value[k] for k in ('keyword','directory_ref','cursor','limit') if k in value}
        result=await reader.search_page(**selected,recursive=True)
        result['operation']='search_recursive'
    else:
        reference={k:value[k] for k in FENCE|{'object_ref','revision','size'}}
        result=await reader.read_utf8(reference,max_bytes=value['max_bytes'],offset=value['offset'])
    await validate(*fence)
    result['location']=manager._file_envelope(value['operation'],(fence[1],fence[2]))['location']
    return result
