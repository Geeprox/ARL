import Foundation
import CoreFoundation
import CryptoKit
import Darwin
import ARLCredentialOnboarding

/// One in-process boundary shared by local file UI and authenticated Mio.
/// It composes the existing NAS model; it never selects credentials or a root.
@MainActor final class NASFileExecutor {
    struct Port {
        let allowed:@MainActor ()->Bool
        let connectSavedScope:@MainActor () async throws->Void
        let consume:@MainActor (String,Data) async throws->Data
        let record:@MainActor (String,UUID,Data,Data?) async throws->Void
        var validateContext:(@MainActor (String,UInt64,String) async throws->Void)? = nil
    }
    private let port:Port
    private var paused=false
    /// Unlinked owner-only temporary FD. Large downloads never retain the whole
    /// file in memory or expose a local path to the caller.
    private final class Spool {
        private let fd: Int32
        private(set) var count = 0
        init() throws {
            var path = Array((NSTemporaryDirectory() + "arl-download-XXXXXX").utf8CString)
            let opened = mkstemp(&path)
            guard opened >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard unlink(path) == 0 else { let code = errno; close(opened); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            fd = opened
        }
        deinit { close(fd) }
        func append(_ bytes: Data) throws {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    offset += n
                }
            }
            count += bytes.count
        }
        func subdata(in range: Range<Int>) throws -> Data {
            guard range.lowerBound >= 0, range.upperBound <= count else { throw OwnerReadFault.invalid }
            var data = Data(count: range.count)
            try data.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = pread(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, off_t(range.lowerBound + offset))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw OwnerReadFault.invalid }
                    offset += n
                }
            }
            return data
        }
    }
    private struct Download {
        let args:Data
        let manifest:Data
        let bytes:Spool
        let deadline:Double
        var delivered = false
    }
    private var download:Download?
    private let now:()->Double

    private var active:(id:UUID,task:Task<Data,Never>)?
    var busy:Bool {active != nil}
    init(port:Port,now:@escaping ()->Double={ProcessInfo.processInfo.systemUptime}){self.port=port;self.now=now}
    func execute(tool:String,argumentsJSON:Data,callID:UUID) async throws->Data {
        let request=try NASCapability.request(tool:tool,argumentsJSON:argumentsJSON)
        if !NASDownloadCapability.names.contains(tool) {_=try NASFileRequest(tool:tool,argumentsJSON:argumentsJSON)}
        try await port.record(tool,callID,argumentsJSON,nil)
        guard !paused,port.allowed(),active==nil else {
            let bytes=try NASCapability.failure(operation:request.operation,code:active != nil ? "nas_busy":"nas_disabled")
            try await port.record(tool,callID,argumentsJSON,bytes);return bytes
        }
        let token=UUID()
        let work=Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                if request.mayRestoreSavedScope {try await port.connectSavedScope()}
                try Task.checkCancellation()
                guard !paused,port.allowed() else{throw CancellationError()}
                let bytes:Data
                if NASDownloadCapability.names.contains(tool) {bytes=try await performDownload(tool:tool,args:argumentsJSON)}
                else {bytes=try await port.consume(tool,argumentsJSON)}
                try Task.checkCancellation()
                guard !paused,port.allowed() else{throw CancellationError()}
                let value=try OwnerReadJSON.object(bytes,limit:196608,maximumDepth:32)
                _=try NASCapability.admit(value,request:request)
                return bytes // Preserve the complete original native return.
            } catch {
                return (try? NASCapability.failure(operation:request.operation,code:Self.code(error))) ?? Data()
            }
        }
        active=(token,work)
        defer{if active?.id==token {active=nil}}
        let bytes=await withTaskCancellationHandler(operation:{await work.value},onCancel:{work.cancel()})
        try await port.record(tool,callID,argumentsJSON,bytes)
        return bytes
    }
    func suspendForExit(){paused=true;active?.task.cancel();download=nil}
    func resumeAfterCancelledExit(){paused=false}
    private func context(_ args:[String:Any]) async throws {
        try Task.checkCancellation()
        guard !paused,port.allowed(),let validate=port.validateContext,
              let source=args["source_ref"] as? String,let gen=NASCapability.integer(args["config_generation"]),gen>0,
              let epoch=args["connection_epoch"] as? String else {throw OwnerReadFault.held}
        try await validate(source,UInt64(gen),epoch)
        try Task.checkCancellation()
        guard !paused,port.allowed() else {throw CancellationError()}
    }
    /// Aggregate only the already reviewed range-reader; never introduce a
    /// second SMB identity, reconnect, or bypass its authority, revision or per-request bounds.
    private func performDownload(tool:String,args input:Data) async throws->Data {
        let args=try OwnerReadJSON.object(input,limit:OwnerReadWire.requestLimit)
        try NASDownloadCapability.validate(tool:tool,args:args)
        try await context(args)
        let instant=now()
        guard instant.isFinite else {throw OwnerReadFault.invalid}
        if let cached=download,instant>=cached.deadline {download=nil}
        if tool=="mio_nas_download" {
            let canonical=try OwnerReadWire.encode(args,limit:OwnerReadWire.requestLimit)
            if let cached=download {
                let previous=try OwnerReadJSON.object(cached.args,limit:OwnerReadWire.requestLimit)
                let sameFence=previous["source_ref"] as? String==args["source_ref"] as? String &&
                    previous["connection_epoch"] as? String==args["connection_epoch"] as? String &&
                    NASCapability.integer(previous["config_generation"])==NASCapability.integer(args["config_generation"])
                if !sameFence {
                    // context(args) has already proved the newly selected live
                    // scope. Retire an obsolete cache, never rebind its old ID.
                    guard previous["operation_id"] as? String != args["operation_id"] as? String else {throw NASRuntimeFailure.sourceChanged}
                    download=nil
                }
            }
            if let cached=download {
                let previous=try OwnerReadJSON.object(cached.args,limit:OwnerReadWire.requestLimit)
                if previous["operation_id"] as? String==args["operation_id"] as? String {
                    guard cached.args==canonical else {throw OwnerReadFault.invalid}
                    return try refreshedManifest(cached)
                }
                // Only one finite download is retained, matching the existing
                // native max-concurrent-read setting; do not evict a live ref.
                if cached.delivered { download=nil }
                else { throw OwnerReadFault.busy }
            }
            let size=NASCapability.integer(args["size"])!,id=args["operation_id"] as! String
            let data=try Spool(); var digest=SHA256()
            repeat {
                try await context(args)
                let length=max(1,min(NASDownloadCapability.chunkBytes,size-data.count)),offset=data.count
                var read:[String:Any]=[:]
                for key in ["source_ref","config_generation","connection_epoch","object_ref","revision"] {read[key]=args[key]}
                read["offset"]=offset;read["length"]=length
                let request=try OwnerReadWire.encode(read,limit:OwnerReadWire.requestLimit)
                let raw=try await port.consume("mio_nas_read",request)
                let page=try OwnerReadJSON.object(raw,limit:196608,maximumDepth:32)
                let expected=try NASCapability.request(tool:"mio_nas_read",argumentsJSON:request)
                guard try NASCapability.admit(page,request:expected),let entry=page["entry"] as? [String:Any],
                      NASCapability.integer(entry["size"])==size,entry["kind"] as? String=="file",
                      let encoded=page["data_base64"] as? String,let bytes=Data(base64Encoded:encoded),bytes.count==min(length,size-offset),
                      bytes.base64EncodedString()==encoded,
                      (offset+bytes.count==size ? NASFileExecutor.boolean(page["eof"],true):NASFileExecutor.boolean(page["eof"],false)),
                      offset+bytes.count==size ? page["next_offset"] is NSNull:NASCapability.integer(page["next_offset"])==offset+bytes.count
                else {throw OwnerReadFault.invalid}
                try data.append(bytes); digest.update(data: bytes)
                try await context(args)
            } while data.count<size
            guard now().isFinite,now()<instant+120 else {throw NASRuntimeFailure.expired}
            var manifest=args
            manifest.merge(["schema_version":1,"operation":"download","transfer_ref":UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
                "sha256":digest.finalize().map { String(format: "%02x", $0) }.joined(),"expires_in_seconds":120.0,"complete":true,"direction":"download",
                "downloadable_artifact":false,"delivery_code":"platform_file_publisher_required"]) {_,new in new}
            guard manifest["operation_id"] as? String==id else {throw OwnerReadFault.invalid}
            let output=try OwnerReadWire.encode(manifest,limit:196608)
            download=Download(args:canonical,manifest:output,bytes:data,deadline:instant+120)
            return try refreshedManifest(download!)
        }
        guard let cached=download,now()<cached.deadline else {throw NASRuntimeFailure.expired}
        let manifest=try OwnerReadJSON.object(cached.manifest,limit:196608)
        for key in ["operation_id","source_ref","connection_epoch","transfer_ref","sha256"] {
            guard args[key] as? String==manifest[key] as? String else {throw NASRuntimeFailure.sourceChanged}
        }
        guard NASCapability.integer(args["config_generation"])==NASCapability.integer(manifest["config_generation"]),
              NASCapability.integer(args["size"])==cached.bytes.count else {throw NASRuntimeFailure.sourceChanged}
        let offset=NASCapability.integer(args["offset"])!,length=NASCapability.integer(args["length"])!
        let end=offset+min(length,cached.bytes.count-offset),bytes=try cached.bytes.subdata(in:offset..<end)
        var reply=args
        reply.merge(["schema_version":1,"operation":"transfer_read","bytes_read":bytes.count,"data_base64":bytes.base64EncodedString(),
            "chunk_sha256":NASDownloadCapability.hash(bytes),"eof":end==cached.bytes.count,"next_offset":end==cached.bytes.count ? NSNull():end as Any,
            "downloadable_artifact":false,"delivery_code":"platform_file_publisher_required"]) {_,new in new}
        try await context(args)
        guard now().isFinite,now()<cached.deadline else {download=nil;throw NASRuntimeFailure.expired}
        if end==cached.bytes.count { download?.delivered=true }
        return try OwnerReadWire.encode(reply,limit:196608)
    }
    private func refreshedManifest(_ cached:Download)throws->Data {
        let remaining=cached.deadline-now()
        guard remaining.isFinite,remaining>0 else {throw NASRuntimeFailure.expired}
        var manifest=try OwnerReadJSON.object(cached.manifest,limit:196608)
        manifest["expires_in_seconds"]=min(120,remaining)
        return try OwnerReadWire.encode(manifest,limit:196608)
    }
    private static func boolean(_ value:Any?,_ expected:Bool)->Bool {
        guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return false}
        return n.boolValue==expected
    }
    static func code(_ error:Error)->String {
        if error is CancellationError{return "cancelled"}
        if let error=error as? NASRuntimeFailure{return error.rawValue}
        if let error=error as? ARLNASFault {
            switch error {
            case .operationInProgress:return "nas_busy"
            case .configurationNotSaved:return "nas_scope_required"
            case .credentialNotSaved:return "nas_credentials_unavailable"
            case .hostNotConfigured,.nativeNASPurposeUnavailable,.nativeResolverUnavailable:return "nas_unavailable"
            case .bindingMismatch,.sourceChanged,.staleGeneration:return "nas_source_changed"
            case .userCancelled:return "cancelled"
            case .connectionFailed:return "nas_not_connected"
            default:return "nas_"+error.rawValue
            }
        }
        if let error=error as? OwnerReadFault{return error.rawValue}
        if let error=error as? CredentialError {
            switch error {
            case .busy:return "nas_busy"
            case .missing:return "nas_credentials_unavailable"
            case .staleReference:return "nas_source_changed"
            default:return "nas_unavailable"
            }
        }
        return "nas_unavailable"
    }
}

/// Page task reference only; admission and finite work remain in NASFileExecutor.
/// Dropping this reference does not cancel a Swift task or its owned NAS pipe.
@MainActor final class NASFilePageTaskHandle {
    private var task: Task<Void, Never>?
    func track(_ task: Task<Void, Never>) { self.task = task }
    func leave() { task = nil }
    func finish() { task = nil }
    func stop() { task?.cancel() }
}
