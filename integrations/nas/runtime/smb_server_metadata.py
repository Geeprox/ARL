"""Encrypted server login and fixed srvsvc share metadata; no file data API.

Wire layout: MS-SRVS NetrShareEnum opnum 15, level 1; DCE/RPC NDR32.
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-srvs/c4a98e7b-d416-439c-97bd-4d9f52f8ba52
"""
import struct
import uuid
from homeplane.nas_connection.contracts import NASConnectionError, relative_path
from homeplane.nas_connection.adapters import Reader, SMBReader

SRVSVC = uuid.UUID('4b324fc8-1670-01d3-1278-5a47bf6ee188').bytes_le
NDR = uuid.UUID('8a885d04-1ceb-11c9-9fe8-08002b104860').bytes_le

def invalid():
    raise NASConnectionError('nas_invalid_request')

def share_name(value):
    if (not isinstance(value, str) or not value or len(value.encode()) > 255
            or any(ord(c) < 32 or ord(c) == 127 or c in '/\\' for c in value)):
        invalid()
    return value

class NDRReader:
    def __init__(self, raw):
        if len(raw) > 65535: invalid()
        self.raw, self.pos = raw, 0
    def take(self, size):
        if size < 0 or self.pos + size > len(self.raw): invalid()
        value = self.raw[self.pos:self.pos+size]; self.pos += size
        return value
    def word(self):
        self.pos = (self.pos + 3) & ~3
        return struct.unpack('<I', self.take(4))[0]
    def text(self):
        maximum, offset, count = self.word(), self.word(), self.word()
        if offset != 0 or not 1 <= count <= maximum <= 4096: invalid()
        raw = self.take(count * 2)
        if raw[-2:] != b'\0\0': invalid()
        try: value = raw[:-2].decode('utf-16-le', errors='strict')
        except UnicodeError: invalid()
        if '\0' in value: invalid()
        return value

def enum_request(resume=0):
    # NULL server binding refers to the already authenticated RPC server.
    return struct.pack('<9I', 0, 1, 1, 0x20000, 0, 0, 4096, 0x20004, resume)

def enum_response(raw):
    n = NDRReader(raw)
    if n.word() != 1 or n.word() != 1: invalid()
    container = n.word()
    rows = []
    if container:
        count, buffer = n.word(), n.word()
        if count > 128 or (count and not buffer): invalid()
        if buffer:
            if n.word() != count: invalid()
            descriptors = [(n.word(), n.word(), n.word()) for _ in range(count)]
            for name_ptr, kind, comment_ptr in descriptors:
                if not name_ptr: invalid()
                name = share_name(n.text())
                if comment_ptr: n.text()  # discarded; never exposed to UI/logs
                # Disk shares only. Administrative/IPC/printer shares are excluded.
                if (kind & 0xFFFF) == 0 and not kind & 0x80000000:
                    rows.append(name)
    total, resume_ptr = n.word(), n.word()
    resume = n.word() if resume_ptr else 0
    status = n.word()
    if n.pos != len(raw) or total > 4096 or len(set(rows)) != len(rows): invalid()
    if status not in (0, 234):
        raise NASConnectionError('nas_access_denied' if status == 5 else 'nas_transport_failed')
    if status == 234 and not resume: invalid()
    return rows, resume if status == 234 else None

def pdu(kind, call, body):
    return struct.pack('<BBBB4sHHI',5,0,kind,3,b'\x10\0\0\0',16+len(body),0,call)+body

def body(raw, kind, call):
    if len(raw) < 16 or len(raw) > 65535: invalid()
    version, minor, packet, flags, representation, length, auth, actual_call = struct.unpack('<BBBB4sHHI',raw[:16])
    if (version,minor,packet,flags,representation,length,auth,actual_call) != (5,0,kind,3,b'\x10\0\0\0',len(raw),0,call): invalid()
    return raw[16:]

class EncryptedServer:
    def __init__(self, endpoint, username, password):
        from smbprotocol.connection import Connection
        from smbprotocol.session import Session
        self.connection = self.session = self.ipc = self.pipe = None
        self.host = endpoint['host']; self.timeout = endpoint['timeout_seconds']
        self.previews = {}
        try:
            self.connection = Connection(uuid.uuid4(), self.host, endpoint['port'], require_signing=True)
            self.connection.connect(timeout=self.timeout)
            self.session = Session(self.connection, username=username, password=password, require_encryption=True, auth_protocol='ntlm')
            self.session.connect()
            if not self.session.encrypt_data or not self.session.session_key:
                raise NASConnectionError('nas_auth_failed')
        except BaseException:
            self.close(); raise

    def _transceive(self, payload):
        from smbprotocol.ioctl import SMB2IOCTLRequest, SMB2IOCTLResponse, CtlCode, IOCTLFlags
        request = SMB2IOCTLRequest()
        request['ctl_code'] = CtlCode.FSCTL_PIPE_TRANSCEIVE
        request['file_id'] = self.pipe.file_id
        request['flags'] = IOCTLFlags.SMB2_0_IOCTL_IS_FSCTL
        request['max_output_response'] = 65535
        request['buffer'] = payload
        pending = self.connection.send(request,sid=self.session.session_id,tid=self.ipc.tree_connect_id)
        response = SMB2IOCTLResponse()
        response.unpack(self.connection.receive(pending,timeout=self.timeout)['data'].get_value())
        return response['buffer'].get_value()

    def _bind(self):
        from smbprotocol.tree import TreeConnect
        from smbprotocol.open import Open, ImpersonationLevel, FilePipePrinterAccessMask, FileAttributes, ShareAccess, CreateDisposition, CreateOptions
        self.ipc = TreeConnect(self.session, f'\\\\{self.host}\\IPC$')
        self.ipc.connect(require_secure_negotiate=True)
        self.pipe = Open(self.ipc,'srvsvc')
        self.pipe.create(ImpersonationLevel.Impersonation,
            FilePipePrinterAccessMask.FILE_READ_DATA | FilePipePrinterAccessMask.FILE_WRITE_DATA,
            FileAttributes.FILE_ATTRIBUTE_NORMAL,ShareAccess.FILE_SHARE_READ | ShareAccess.FILE_SHARE_WRITE,
            CreateDisposition.FILE_OPEN,CreateOptions.FILE_NON_DIRECTORY_FILE)
        context = struct.pack('<HBB',0,1,0)+SRVSVC+struct.pack('<HH',3,0)+NDR+struct.pack('<I',2)
        result = body(self._transceive(pdu(11,1,struct.pack('<HHIB3x',65535,65535,0,1)+context)),12,1)
        if len(result) < 12: invalid()
        address_size = struct.unpack_from('<H',result,8)[0]
        offset = (10+address_size+3)&~3
        if offset+28 != len(result) or result[offset:offset+4] != b'\x01\0\0\0': invalid()
        acceptance, reason = struct.unpack_from('<HH',result,offset+4)
        if acceptance != 0 or reason != 0 or result[offset+8:offset+24] != NDR or struct.unpack_from('<I',result,offset+24)[0] != 2: invalid()

    def shares(self, resume=0):
        if self.pipe is None: self._bind()
        stub = enum_request(resume)
        response = body(self._transceive(pdu(0,2,struct.pack('<IHH',len(stub),0,15)+stub)),2,2)
        if len(response) < 8: invalid()
        allocation, context, cancel, reserved = struct.unpack('<IHBB',response[:8])
        if context != 0 or cancel != 0 or reserved != 0 or allocation != len(response)-8: invalid()
        return enum_response(response[8:])

    def directories(self, share, path, cursor):
        from smbprotocol.tree import TreeConnect
        share_name(share); relative_path(path,allow_root=True)
        preview = self.previews.get(share)
        if preview is None:
            # Same authenticated encrypted session, selected real share only.
            # The preview calls only list_page; no read/stat/upload is exposed.
            if len(self.previews) >= 8: raise NASConnectionError('nas_budget_exceeded')
            preview = object.__new__(SMBReader); Reader.__init__(preview)
            preview.connection,preview.session,preview.root = self.connection,self.session,''
            preview.tree = TreeConnect(self.session,f'\\\\{self.host}\\{share}')
            preview.tree.connect(require_secure_negotiate=True)
            if preview.tree.is_dfs_share:
                preview.tree.disconnect(); raise NASConnectionError('nas_access_denied')
            self.previews[share] = preview
        page = preview.list_page(path,cursor,128)
        return {'path':path,'directories':[x['path'] for x in page['entries'] if x['kind']=='directory'],'next_cursor':page['cursor']}

    def close(self):
        for preview in self.previews.values():
            try: preview.close_cursors(); preview.tree.disconnect()
            except Exception: pass
        self.previews.clear()
        for value, method in ((self.pipe,'close'),(self.ipc,'disconnect'),(self.session,'disconnect'),(self.connection,'disconnect')):
            if value is not None:
                try: getattr(value,method)()
                except Exception: pass
        self.pipe = self.ipc = self.session = self.connection = None
