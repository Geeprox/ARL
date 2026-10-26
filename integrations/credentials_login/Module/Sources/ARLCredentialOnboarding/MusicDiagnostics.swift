import Foundation
import CoreFoundation
import OSLog

/// Only public operation/schema fields; descriptions, defaults and values are not accepted.
struct MusicCloudCatalogMetadata: Codable, Sendable, Equatable {
    struct Parameter: Codable, Sendable, Equatable {
        let name:String
        let type:String
        let location:String
        let required:String
    }
    struct Entry: Codable, Sendable, Equatable {
        let operation:[String]
        let endpoint:String
        let httpMethod:String
        let authRequired:String
        let parameterCount:Int
        let schemaComplete:Bool
        let parameters:[Parameter]
        enum CodingKeys:String,CodingKey {
            case operation,endpoint,parameters,httpMethod="http_method",authRequired="auth_required",
                 parameterCount="parameter_count",schemaComplete="schema_complete"
        }
    }
    let schemaVersion:Int
    let coverage:String
    let scannedMethods:Int
    let matchedMethods:Int
    let omittedCandidates:Int
    let skippedGroups:Int
    let uninspectableMethods:Int
    let entries:[Entry]
    enum CodingKeys:String,CodingKey {
        case schemaVersion="schema_version",coverage,scannedMethods="scanned_methods",matchedMethods="matched_methods",
             omittedCandidates="omitted_candidates",skippedGroups="skipped_groups",
             uninspectableMethods="uninspectable_methods",entries
    }
    static func decode(_ value:Any) throws -> Self {
        guard let root=value as? [String:Any],Set(root.keys)==Set(CodingKeys.all),
              let rows=root["entries"] as? [[String:Any]],rows.count<=24,
              rows.allSatisfy({ row in
                  guard Set(row.keys)==["operation","endpoint","http_method","auth_required","parameter_count","schema_complete","parameters"],
                        let fields=row["parameters"] as? [[String:Any]],fields.count<=16 else {return false}
                  return fields.allSatisfy {Set($0.keys)==["name","type","location","required"]}
              }) else {throw CredentialError.uncertainLocalState}
        let bytes=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys,.withoutEscapingSlashes])
        guard bytes.count<=8192 else {throw CredentialError.uncertainLocalState}
        let result=try JSONDecoder().decode(Self.self,from:bytes)
        try result.validate();return result
    }
    func validate() throws {
        func token(_ value:String)->Bool {
            value.range(of:#"\A[A-Za-z][A-Za-z0-9_-]{0,63}\z"#,options:.regularExpression) != nil
        }
        guard schemaVersion==1,["complete","partial","invalid"].contains(coverage),
              [scannedMethods,matchedMethods,omittedCandidates,skippedGroups,uninspectableMethods].allSatisfy({(0...16384).contains($0)}),
              entries.count<=24,matchedMethods==entries.count+omittedCandidates,scannedMethods>=matchedMethods,
              uninspectableMethods<=scannedMethods else {throw CredentialError.uncertainLocalState}
        for row in entries {
            guard (1...5).contains(row.operation.count),row.operation.allSatisfy(token),
                  row.endpoint.utf8.count<=256,
                  row.endpoint.range(of:#"\A/openapi/[A-Za-z0-9_/{}:-]+\z"#,options:.regularExpression) != nil,
                  ["GET","POST","PUT","DELETE","PATCH","HEAD","OPTIONS","unknown"].contains(row.httpMethod),
                  ["true","false","unknown"].contains(row.authRequired),(-1...128).contains(row.parameterCount),
                  row.parameters.count<=16,(row.parameterCount == -1 ? row.parameters.isEmpty && !row.schemaComplete : row.parameters.count<=row.parameterCount),
                  row.parameters.allSatisfy({
                      token($0.name)&&["integer","number","string","boolean","array","object","file","unknown"].contains($0.type) &&
                      ["query","body","path","header","unknown","conflict"].contains($0.location) &&
                      ["true","false","unknown"].contains($0.required)
                  }) else {throw CredentialError.uncertainLocalState}
            if row.schemaComplete {
                guard row.parameters.count==row.parameterCount,row.httpMethod != "unknown",row.authRequired != "unknown",
                      Set(row.parameters.map(\.name)).count==row.parameters.count,
                      row.parameters.allSatisfy({$0.type != "unknown" && !["unknown","conflict"].contains($0.location) && $0.required != "unknown"})
                else {throw CredentialError.uncertainLocalState}
            }
        }
        let complete=omittedCandidates==0&&skippedGroups==0&&uninspectableMethods==0&&entries.allSatisfy(\.schemaComplete)
        if coverage=="invalid" {
            guard entries.isEmpty,scannedMethods==0,matchedMethods==0,omittedCandidates==0,skippedGroups==1,uninspectableMethods==0
            else {throw CredentialError.uncertainLocalState}
        } else if (coverage=="complete") != complete {throw CredentialError.uncertainLocalState}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        guard try encoder.encode(self).count<=8192 else {throw CredentialError.uncertainLocalState}
    }
}
private extension MusicCloudCatalogMetadata.CodingKeys {
    static let all=["schema_version","coverage","scanned_methods","matched_methods","omitted_candidates","skipped_groups","uninspectable_methods","entries"]
}

/// Bounded diagnostics: provider text is redacted by the bridge before UTF-8 truncation; no raw response or auth data.
struct MusicDiagnostic: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable, CaseIterable {
        case owner, initialize, qr_create, qr_payload, qr_delivery, qr_display, qr_poll, account_read, effect, readback, token_store, bridge, provider, complete
        var title:String {
            switch self {
            case .owner: "读取本地配置"
            case .initialize: "初始化官方程序"
            case .qr_create: "创建二维码"
            case .qr_payload: "核对内容"
            case .qr_delivery: "接收"
            case .qr_display: "显示"
            case .qr_poll: "查询扫码状态"
            case .account_read: "验证账号访问"
            case .effect: "提交一次写入"
            case .readback: "只读查证写入结果"
            case .token_store: "保存登录会话"
            case .bridge: "校验程序响应"
            case .provider: "请求网易云服务"
            case .complete: "确认操作结果"
            }
        }
    }
    enum Kind:String,Codable,Sendable,CaseIterable {
        case started,succeeded,waiting,confirming,ignored,expired,provider_rejected,network_unavailable,network_timeout,not_dispatched
        case signing_failed,invalid_response,runtime_exited,storage_failed,cancelled,unconfirmed,cleanup_unproven,endpoint_rejected,login_required,timed_out
        var failed:Bool { ![Self.started,.succeeded,.waiting,.confirming,.ignored].contains(self) }
    }
    enum EndpointClass:String,Codable,Sendable,CaseIterable {
        case official_api,official_qr_create,official_qr_poll,public_ip_lookup,package_update,other
    }
    enum ReasonCode:String,Codable,Sendable,CaseIterable {
        case endpoint_scheme,endpoint_host,endpoint_port,endpoint_credentials,endpoint_socket,endpoint_tls,network_disabled
        case qr_missing_value,qr_wrong_type,qr_empty_value,qr_too_long,qr_url_invalid,qr_url_scheme,qr_url_host,qr_url_credentials,qr_url_port
        case qr_frame_invalid,qr_frame_write,qr_not_delivered,qr_render,stale_callback,login_unconfirmed
    }
    let callID:UUID
    let phase:Phase
    let kind:Kind
    let httpStatus:Int?
    let code:Int?
    let subCode:Int?
    let providerStatus:Int?
    let elapsedMS:Int
    var requestID:UUID? = nil
    var endpointClass:EndpointClass? = nil
    var reasonCode:ReasonCode? = nil
    var providerCode:String? = nil
    var providerMessage:String? = nil
    var providerMsg:String? = nil
    var cloudCatalog:[String:String]? = nil
    var cloudMetadata:MusicCloudCatalogMetadata? = nil
    var message:String {
        let explanation:String = switch kind {
        case .signing_failed: "应用私钥未通过官方签名处理。请核对开放平台提供的 PrivateKey 格式；不要重复扫码。"
        case .provider_rejected: "网易云拒绝了请求。请依据下方错误码核查应用配置或平台状态；不要重复扫码。"
        case .network_unavailable,.network_timeout: "网络请求未完成。请检查网络连接后再手动尝试。"
        case .endpoint_rejected: "官方程序请求超出当前已核验连接范围，已停止。需要检查应用接入实现。"
        case .not_dispatched: "此次写入在发出前已停止；原请求仍禁止自动重放，请使用只读核实入口。"
        case .storage_failed: "本地安全保存未完成；不要重复授权，请先检查本地保存错误。"
        case .invalid_response:
            switch phase {
            case .qr_payload: "二维码内容不可用。\n服务成功码不代表二维码有效。\n请检查应用的登录功能。"
            case .qr_delivery: "二维码传递未完成。\n本次未收到有效二维码。\n请检查应用的登录功能。"
            case .qr_display: "二维码未能显示。\n请检查应用的登录功能。"
            default: "官方响应或桥接格式未通过校验，需要检查接入实现。"
            }
        case .expired: "二维码已过期，可手动刷新。"
        case .timed_out: "本次扫码等待已结束，可手动刷新二维码；未自动重试。"
        case .login_required: "尚未取得有效登录授权。"
        case .cleanup_unproven: "登录程序清理尚未确认，请等待处理，勿重复开始。"
        case .cancelled: "操作已取消，未自动重试。"
        default: "本次结果尚未确认，请提供此诊断编号以定位原因。"
        }
        let codes=[httpStatus.map{"HTTP \($0)"},code.map{"code \($0)"},subCode.map{"subCode \($0)"}].compactMap{$0}.joined(separator:"，")
        return "网易云：\(phase.title)阶段。\(explanation)"+(codes.isEmpty ? "":"\n\(codes)")+"\n诊断编号：\(callID.uuidString)"
    }
    static func decode(_ frame:[String:Any],callID:String,expectedSequence:Int) throws -> MusicDiagnostic {
        let required:Set<String>=["schema","call_id","event","sequence","phase","kind","http_status","code","sub_code","provider_status","elapsed_ms"]
        guard required.isSubset(of:Set(frame.keys)),Set(frame.keys).isSubset(of:required.union(["endpoint_class","reason_code","provider_code","provider_message","provider_msg","cloud_catalog","cloud_metadata"])),
              frame["call_id"] as? String==callID,let id=UUID(uuidString:callID),
              let phase=Phase(rawValue:frame["phase"] as? String ?? ""),let kind=Kind(rawValue:frame["kind"] as? String ?? ""),
              number(frame["sequence"],range:1...128)==expectedSequence,
              let elapsed=number(frame["elapsed_ms"],range:0...360000)
        else { throw CredentialError.uncertainLocalState }
        func optional(_ key:String,_ range:ClosedRange<Int>) throws -> Int? {
            if frame[key] is NSNull { return nil }
            guard let value=number(frame[key],range:range) else { throw CredentialError.uncertainLocalState };return value
        }
        var endpoint:EndpointClass?,reason:ReasonCode?
        if let value=frame["endpoint_class"],!(value is NSNull) {
            guard let text=value as? String,let decoded=EndpointClass(rawValue:text) else {throw CredentialError.uncertainLocalState};endpoint=decoded
        }
        if let value=frame["reason_code"],!(value is NSNull) {
            guard let text=value as? String,let decoded=ReasonCode(rawValue:text) else {throw CredentialError.uncertainLocalState};reason=decoded
        }
        let providerCode=try providerText(frame["provider_code"],limit:64,phase:phase,kind:kind),
            providerMessage=try providerText(frame["provider_message"],limit:512,phase:phase,kind:kind),
            providerMsg=try providerText(frame["provider_msg"],limit:512,phase:phase,kind:kind)
        let catalog=try catalogFields(frame["cloud_catalog"],phase:phase,kind:kind)
        var metadata:MusicCloudCatalogMetadata?
        if let value=frame["cloud_metadata"] {
            guard phase == .provider,kind == .ignored else {throw CredentialError.uncertainLocalState}
            metadata=try MusicCloudCatalogMetadata.decode(value)
        }
        return try .init(callID:id,phase:phase,kind:kind,httpStatus:optional("http_status",100...599),
            code:optional("code",-999999...999999),subCode:optional("sub_code",-999999...999999),
            providerStatus:optional("provider_status",0...9999),elapsedMS:elapsed,endpointClass:endpoint,reasonCode:reason,providerCode:providerCode,providerMessage:providerMessage,providerMsg:providerMsg,cloudCatalog:catalog,cloudMetadata:metadata)
    }
    private static func catalogFields(_ value:Any?,phase:Phase,kind:Kind) throws -> [String:String]? {
        guard let value else {return nil}
        guard phase == .provider,kind == .ignored,let fields=value as? [String:String],
              let state=fields["state"],["missing","ambiguous","invalid","observed"].contains(state)
        else {throw CredentialError.uncertainLocalState}
        if state != "observed" {
            guard Set(fields.keys)==["state"] else {throw CredentialError.uncertainLocalState}
            return fields
        }
        let expected:Set<String>=["state","group","command","http_method","auth_required","parameter_count",
            "extra_required_parameters","offset_type","offset_required","offset_location",
            "limit_type","limit_required","limit_location"]
        guard Set(fields.keys)==expected,
              ["group","command"].allSatisfy({ fields[$0]?.range(of:#"\A[a-z][a-zA-Z0-9_]{0,31}\z"#,options:.regularExpression) != nil }),
              ["GET","POST","unknown"].contains(fields["http_method"]!),
              ["true","false","unknown"].contains(fields["auth_required"]!),
              ["parameter_count","extra_required_parameters"].allSatisfy({
                  guard let raw=fields[$0],let n=Int(raw),(0...128).contains(n) else {return false}
                  return String(n)==raw
              }),
              ["offset","limit"].allSatisfy({
                  ["integer","number","string","boolean","array","object","unknown","missing"].contains(fields[$0+"_type"]!) &&
                  ["true","false","unknown","missing"].contains(fields[$0+"_required"]!) &&
                  ["query","body","path","unknown","missing","conflict"].contains(fields[$0+"_location"]!)
              })
        else {throw CredentialError.uncertainLocalState}
        return fields
    }
    private static func providerText(_ value:Any?,limit:Int,phase:Phase,kind:Kind) throws -> String? {
        guard let value,!(value is NSNull) else {return nil}
        guard phase == .effect,kind == .provider_rejected,let text=value as? String,
              !text.isEmpty,text.utf8.count<=limit,
              text==text.trimmingCharacters(in:.whitespacesAndNewlines),
              !text.unicodeScalars.contains(where:{[.control,.format,.surrogate].contains($0.properties.generalCategory)})
        else {throw CredentialError.uncertainLocalState}
        // Defense in depth on the paired bridge's already-cleaned result.
        // This layer has no access to credentials; it never reads them to log.
        let forbidden = #"(?i)[a-z][a-z0-9+.-]*://|www\.|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|\b[0-9a-f]{12,}\b|\b[0-9]{5,}\b|(?:%[0-9a-f]{2}){3,}|-----BEGIN|\b(?:authorization|proxy-authorization|cookie|set-cookie|x-[a-z0-9-]+)\s*:|\b(?:access[_-]?token|refresh[_-]?token|namedtoken|token|private[_-]?key|api[_-]?key|client[_-]?secret|signature|sign|account|username|nickname|phone|email|uid|(?:user|account|device|app|session|request|trace|original)[_-]?id)\s*[:=]|\b(?:bearer|basic)\s+[a-z0-9+/_=.-]+"#
        let encodedIdentifier = #"\b(?=[A-Za-z0-9+/_=-]{24,}(?:\b|$))(?=[A-Za-z0-9+/_=-]*[a-z])(?=[A-Za-z0-9+/_=-]*[A-Z])(?=[A-Za-z0-9+/_=-]*[0-9])[A-Za-z0-9+/_=-]{24,}"#
        guard text.range(of:forbidden,options:.regularExpression)==nil,
              text.range(of:encodedIdentifier,options:.regularExpression)==nil
        else {throw CredentialError.uncertainLocalState}
        return text
    }
    func validateProviderFields() throws {
        if let cloudMetadata {
            guard phase == .provider,kind == .ignored else {throw CredentialError.uncertainLocalState}
            try cloudMetadata.validate()
        }
        _=try Self.catalogFields(cloudCatalog,phase:phase,kind:kind)
        _=try Self.providerText(providerCode,limit:64,phase:phase,kind:kind)
        _=try Self.providerText(providerMessage,limit:512,phase:phase,kind:kind)
        _=try Self.providerText(providerMsg,limit:512,phase:phase,kind:kind)
    }
    private static func number(_ value:Any?,range:ClosedRange<Int>) -> Int? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,
              n.doubleValue.rounded()==n.doubleValue,range.contains(n.intValue) else { return nil };return n.intValue
    }
}
struct MusicDiagnosticFailure:Error,Sendable { let diagnostic:MusicDiagnostic }

final class MusicDiagnosticTrace:@unchecked Sendable {
    let id=UUID()
    let requestID:UUID?
    private let started=ProcessInfo.processInfo.systemUptime
    private let lock=NSLock()
    private var failure:MusicDiagnostic?
    private var qrResponseSucceeded=false
    private var qrDelivered=false
    private let sink:@Sendable (MusicDiagnostic)->Void
    init(requestID:UUID?=nil,sink:@escaping @Sendable (MusicDiagnostic)->Void=MusicDiagnostics.log) {
        self.requestID=requestID;self.sink=sink
    }
    var lastFailure:MusicDiagnostic? { lock.withLock{failure} }
    func accept(_ entry:MusicDiagnostic) {
        guard entry.callID==id else { return }
        var bound=entry;bound.requestID=requestID
        lock.withLock {
            if bound.phase == .qr_create,bound.kind == .succeeded,let status=bound.httpStatus,(200..<300).contains(status) {
                qrResponseSucceeded=true // HTTP evidence only; not valid QR or login evidence.
            }
            if bound.phase == .qr_delivery,bound.kind == .succeeded {qrDelivered=true}
            if bound.kind.failed { failure=bound }
            else if [.qr_payload,.qr_delivery].contains(bound.phase),bound.kind == .succeeded,
                    failure?.phase == .provider,failure?.kind == .endpoint_rejected {
                // The denied request remains in the log. A later independently
                // validated QR supersedes it only for the displayed failure.
                failure=nil
            }
        };sink(bound)
    }
    func record(_ phase:MusicDiagnostic.Phase,_ kind:MusicDiagnostic.Kind,reason:MusicDiagnostic.ReasonCode?=nil) {
        accept(.init(callID:id,phase:phase,kind:kind,httpStatus:nil,code:nil,subCode:nil,providerStatus:nil,
            elapsedMS:max(0,min(360000,Int((ProcessInfo.processInfo.systemUptime-started)*1000))),reasonCode:reason))
    }
    func loginUnconfirmed(qrDelivered:Bool) {
        let needsTerminal=lock.withLock { failure == nil ||
            (failure?.phase == .complete && failure?.kind == .unconfirmed) ||
            (qrResponseSucceeded && failure?.phase == .provider && failure?.kind == .endpoint_rejected) }
        guard needsTerminal else {return} // Preserve a concrete current QR/poll/storage failure.
        if qrDelivered {record(.complete,.unconfirmed,reason:.login_unconfirmed)}
        else {record(.qr_delivery,.invalid_response,reason:.qr_not_delivered)}
    }
    func loginRuntimeFailed(_ error:any Error) {
        if error is CancellationError || error as? TransportFailure == .timeout || error as? MusicLoginRuntimeFailure == .expired {
            fail(error,phase:.complete);return
        }
        let missingQR=lock.withLock {qrResponseSucceeded && !qrDelivered && (failure == nil ||
            (failure?.phase == .complete && failure?.kind == .unconfirmed) ||
            (failure?.phase == .provider && failure?.kind == .endpoint_rejected))}
        if missingQR {record(.qr_delivery,.invalid_response,reason:.qr_not_delivered)}
        else if lastFailure == nil {fail(error,phase:.bridge)}
    }
    func fail(_ error:any Error,phase:MusicDiagnostic.Phase) {
        let kind:MusicDiagnostic.Kind
        if error is CancellationError { kind = .cancelled }
        else if error as? MusicReadRuntimeFailure == .cleanupUnproven { kind = .cleanup_unproven }
        else if error as? TransportFailure == .timeout { kind = .timed_out }
        else if error as? MusicLoginRuntimeFailure == .runtimeExited { kind = .runtime_exited }
        else if error as? MusicLoginRuntimeFailure == .expired { kind = .expired }
        else if error as? CredentialError == .storageUnavailable || error is CredentialStorageFailure || error is LoginACLFailure { kind = .storage_failed }
        else if phase == .token_store { kind = .storage_failed }
        else { kind = .invalid_response }
        record(phase,kind)
    }
}
enum MusicDiagnostics {
    @TaskLocal static var current:MusicDiagnosticTrace?
    private static let logger=Logger(subsystem:"local.arl.control",category:"netease-diagnostic")
    static func log(_ entry:MusicDiagnostic) {
        // Apply the same field bounds at the public-log boundary as at wire decoding.
        do {try entry.validateProviderFields()} catch {return}
        guard let bytes=try? JSONEncoder().encode(entry),let text=String(data:bytes,encoding:.utf8) else { return }
        logger.notice("netease_diagnostic_v1 \(text,privacy:.public)")
    }
}

/// Associates owner calls with bounded provider traces without logging query text.
public enum MusicReadRequestContext {
    @TaskLocal public static var requestID: UUID?
}
