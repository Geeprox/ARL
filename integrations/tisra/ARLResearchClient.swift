import Foundation
import CryptoKit

/// Source API v1. The local format ID is separate from three negotiated wire versions.
public struct ARLResearchDescriptor: Sendable {
    public let executionID, threadID: UUID
    public let sequence: Int
    public let parentRunID: UUID?
    public let parentFingerprint: String?
    public let startsAlternatePath: Bool
    public let model: String
    public let requestDigest: String
    public let requestBytes, maximumResponseBytes, maximumOutputTokens: Int
    public let evidence: [(id: UUID, snapshotDigest: String)]
    public init(executionID: UUID, threadID: UUID, sequence: Int, parentRunID: UUID? = nil,
                parentFingerprint: String? = nil, startsAlternatePath: Bool = false,
                model: String, requestDigest: String, requestBytes: Int,
                maximumResponseBytes: Int = 1_048_576, maximumOutputTokens: Int = 4096,
                evidence: [(id: UUID, snapshotDigest: String)]) {
        self.executionID=executionID; self.threadID=threadID; self.sequence=sequence
        self.parentRunID=parentRunID; self.parentFingerprint=parentFingerprint
        self.startsAlternatePath=startsAlternatePath; self.model=model
        self.requestDigest=requestDigest; self.requestBytes=requestBytes
        self.maximumResponseBytes=maximumResponseBytes; self.maximumOutputTokens=maximumOutputTokens
        self.evidence=evidence
    }
    var wire: [String:ARLJSON] { [
        "version":.number(1), "executionID":.string(executionID.uuidString.lowercased()),
        "threadID":.string(threadID.uuidString.lowercased()), "sequence":.number(Double(sequence)),
        "parentRunID":parentRunID.map { .string($0.uuidString.lowercased()) } ?? .null,
        "parentFingerprint":parentFingerprint.map { .string($0) } ?? .null,
        "startsAlternatePath":.bool(startsAlternatePath), "model":.string(model),
        "format":.string("openai.responses.v1"), "requestDigest":.string(requestDigest),
        "requestBytes":.number(Double(requestBytes)), "maximumResponseBytes":.number(Double(maximumResponseBytes)),
        "maximumOutputTokens":.number(Double(maximumOutputTokens)),
        "evidence":.array(evidence.map { .object(["evidenceID":.string($0.id.uuidString.lowercased()), "snapshotDigest":.string($0.snapshotDigest)]) })
    ] }
}

public struct ARLResearchPayload: Codable, Sendable, Equatable {
    public let payload_id: String
    public let sha256: String
    public let byte_count: Int
}
public struct ARLResearchReceipt: Codable, Sendable, Equatable {
    public let schema_version: Int
    public let job_id, owner, run_id, request_sha256: String
    public let epoch: Int
    public let auth_epoch, state, provider, model, model_fingerprint: String
    public let request_format, output_format, history_version: String
    public let result_ref: ARLResearchPayload?
    public let error_code: String?
    public let cancel_requested: Bool
    public let external_stop: String
}
public struct ARLResearchSubmission: Sendable {
    public let receipt: ARLResearchReceipt
    fileprivate let params: [String:ARLJSON]

    /// Metadata only. Persist these exact bytes and their digest in trusted local
    /// storage; a digest recomputed from untrusted input is not a scope pin.
    public func durableRecord() throws -> Data {
        // Synthesized Codable omits nil fields; the strict wire receipt requires
        // explicit nulls so restored and live receipt validation are identical.
        let encoded = try JSONEncoder().encode(receipt)
        guard case .object(var fields) = try JSONDecoder().decode(ARLJSON.self, from: encoded) else {
            throw ARLError(code: "research_restore_mismatch")
        }
        for key in ["result_ref", "error_code"] where fields[key] == nil { fields[key] = .null }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ARLJSON.object([
            "schema_version": .number(1), "receipt": .object(fields), "params": .object(params)
        ]))
        guard data.count <= 65_300 else { throw ARLError(code: "research_restore_mismatch") }
        return data
    }
}

public struct ARLResearchPayloadRecord: Codable, Sendable {
    public let owner, run_id, purpose, payload_id, sha256: String
    public let epoch, byte_count: Int
}
public struct ARLResearchCleanupPending: Error, Sendable {
    public let payloadIDs: [String]
}

/// Source-only: no bootstrap, credentials, grants or inference on construction.
public actor ARLResearchClient {
    private let exchange: @Sendable (String, [String: ARLJSON]) async throws -> ARLJSON
    private let owner: String
    private var authPins: [String: String] = [:]
    private static let receiptKeys: Set<String> = ["schema_version","job_id","owner","run_id","request_sha256","epoch","auth_epoch","state","provider","model","model_fingerprint","request_format","output_format","history_version","result_ref","error_code","cancel_requested","external_stop"]
    private static let states: Set<String> = ["queued","running","succeeded","failed","cancelled","needs_unlock","needs_review"]
    public init(home: URL, app: String = "tisra") {
        owner = app
        let client = ARLClient(home: home, app: app)
        exchange = { method, params in try await client.rpc(method, params: params) }
    }
    #if RESEARCH_CLIENT_FIXTURE
    init(fixtureOwner: String, exchange: @escaping @Sendable (String, [String: ARLJSON]) async throws -> ARLJSON) {
        owner = fixtureOwner; self.exchange = exchange
    }
    #endif
    public static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func canonicalUUID(_ text: String) -> Bool { UUID(uuidString:text)?.uuidString.lowercased() == text }
    private static func hash(_ text: String) -> Bool { text.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil }
    private func rpc(_ method: String, _ params: [String:ARLJSON] = [:]) async throws -> ARLJSON {
        let result = try await exchange(method, params)
        guard try JSONEncoder().encode(result).count <= 65_300 else { throw ARLError(code:"invalid_response") }
        return result
    }
    public func capabilities() async throws -> ARLJSON { try await rpc("research.capabilities.v1") }
    /// Reconstruct a known accepted job without upload, submit, or any RPC.
    /// expectedSHA256 must come from the consumer's trusted acceptance record.
    /// This local integrity binding does not grant server authority or replace
    /// the consumer's Ledger/cancellation epoch checks.
    public func restoreSubmission(from data: Data, expectedSHA256: String) throws -> ARLResearchSubmission {
        guard (1...65_300).contains(data.count), Self.hash(expectedSHA256),
              Self.digest(data) == expectedSHA256 else { throw ARLError(code: "research_restore_mismatch") }
        let value: ARLJSON
        do { value = try JSONDecoder().decode(ARLJSON.self, from: data) }
        catch { throw ARLError(code: "research_restore_mismatch") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Only the exact exported local representation is accepted. In
        // particular, duplicate JSON keys cannot be collapsed during decoding.
        guard try encoder.encode(value) == data else { throw ARLError(code: "research_restore_mismatch") }
        guard case .object(let record) = value,
              Set(record.keys) == Set(["schema_version", "receipt", "params"]),
              record["schema_version"] == .number(1), let receipt = record["receipt"],
              case .object(let params) = record["params"], Self.validRestoreParams(params) else {
            throw ARLError(code: "research_restore_mismatch")
        }
        // checked pins the persisted original auth_epoch before status/cancel.
        // Malformed receipt/scope must not poison pins or cause an RPC.
        let accepted = try checked(receipt, params)
        return ARLResearchSubmission(receipt: accepted, params: params)
    }
    private static func validRestoreParams(_ p: [String: ARLJSON]) -> Bool {
        func integer(_ v: ARLJSON?, _ range: ClosedRange<Double>) -> Bool {
            guard case .number(let n) = v else { return false }
            return n.isFinite && n.rounded() == n && range.contains(n)
        }
        func text(_ v: ARLJSON?, limit: Int = 200) -> Bool {
            guard let s = v?.text else { return false }
            return (1...limit).contains(s.unicodeScalars.count) && !s.unicodeScalars.contains { $0.value < 32 }
        }
        func payload(_ v: ARLJSON?, limit: Double) -> Bool {
            guard case .object(let r) = v, Set(r.keys) == Set(["payload_id", "sha256", "byte_count"]),
                  let id = r["payload_id"]?.text, canonicalUUID(id),
                  let digest = r["sha256"]?.text, hash(digest) else { return false }
            return integer(r["byte_count"], 1...limit)
        }
        return Set(p.keys) == Set(["schema_version", "run_id", "epoch", "request", "descriptor", "provider", "model",
                                  "model_fingerprint", "request_format", "output_format", "history_version",
                                  "max_output_tokens", "priority", "deadline_ms"]) &&
            p["schema_version"] == .number(1) &&
            p["run_id"]?.text.map(canonicalUUID) == true && integer(p["epoch"], 0...2_147_483_647) &&
            payload(p["request"], limit: 524_288) && payload(p["descriptor"], limit: 32_768) &&
            text(p["provider"]) && text(p["model"]) && text(p["model_fingerprint"]) &&
            p["request_format"] == .string("openai.responses.request.v1") &&
            p["output_format"] == .string("openai.responses.envelope.v1") &&
            p["history_version"] == .string("openai.responses.history.v1") &&
            integer(p["max_output_tokens"], 1...4096) && text(p["priority"], limit: 20) &&
            integer(p["deadline_ms"], 1...600_000)
    }
    /// One bounded revoke pass, independent of cancellation of the submit task.
    /// Pending opaque IDs must remain in the consumer's durable cancellation record.
    public func cleanupPayloads(_ ids: [String]) async throws {
        let unique = Array(Set(ids)).sorted()
        guard unique.count <= 16, unique.allSatisfy(Self.canonicalUUID) else { throw ARLError(code:"invalid_arguments") }
        let pending = await Task.detached { [self] in
            var pending: [String] = []
            for id in unique {
                do {
                    let ack = try await self.rpc("payload.revoke.v1", ["payload_id":.string(id)])
                    guard ack == .object(["schema_version":.number(1),"revoked":.bool(true),"external_stop":.string("unknown")]) else { throw ARLError(code:"invalid_response") }
                } catch { pending.append(id) }
            }
            return pending
        }.value
        if !pending.isEmpty { throw ARLResearchCleanupPending(payloadIDs: pending) }
    }
    private func upload(_ bytes: Data, purpose: String, run: UUID, epoch: Int,
                        created: inout [String], onPayloadCreated: (@Sendable (ARLResearchPayloadRecord) async throws -> Void)?) async throws -> [String:ARLJSON] {
        try Task.checkCancellation()
        let hash=Self.digest(bytes)
        let begin=try await rpc("payload.begin.v1",["purpose":.string(purpose),"run_id":.string(run.uuidString.lowercased()),"epoch":.number(Double(epoch)),"sha256":.string(hash),"byte_count":.number(Double(bytes.count))])
        guard let id=begin["payload_id"]?.text, Self.canonicalUUID(id) else { throw ARLError(code:"invalid_response") }
        created.append(id)
        if let onPayloadCreated {
            try await onPayloadCreated(ARLResearchPayloadRecord(owner:owner,run_id:run.uuidString.lowercased(),purpose:purpose,payload_id:id,sha256:hash,epoch:epoch,byte_count:bytes.count))
        }
        try Task.checkCancellation()
        guard case .object(let b)=begin, Set(b.keys)==Set(["schema_version","payload_id","expires_at_ms","chunk_bytes"]),
              begin["schema_version"] == .number(1), begin["chunk_bytes"] == .number(8192),
              case .number(let expiry) = begin["expires_at_ms"], expiry.isFinite, expiry>=0, expiry.rounded()==expiry, expiry<=9_007_199_254_740_991 else { throw ARLError(code:"invalid_response") }
        for offset in stride(from:0,to:bytes.count,by:8192) {
            try Task.checkCancellation()
            let chunk=bytes.subdata(in:offset..<min(bytes.count,offset+8192))
            let params: [String:ARLJSON] = ["payload_id":.string(id),"index":.number(Double(offset/8192)),"data_base64":.string(chunk.base64EncodedString()),"sha256":.string(Self.digest(chunk))]
            let ack: ARLJSON
            do { ack = try await rpc("payload.write.v1",params) }
            catch let error as ARLError where error.code == "disconnected" { try Task.checkCancellation(); ack = try await rpc("payload.write.v1",params) }
            try Task.checkCancellation()
            guard ack == .object(["schema_version":.number(1),"accepted_index":.number(Double(offset/8192))]) else { throw ARLError(code:"invalid_response") }
        }
        let value: [String:ARLJSON] = ["payload_id":.string(id),"sha256":.string(hash),"byte_count":.number(Double(bytes.count))]
        try Task.checkCancellation()
        let sealed=try await rpc("payload.seal.v1",value)
        try Task.checkCancellation()
        guard case .object(let seal)=sealed, Set(seal.keys)==Set(value.keys).union(["schema_version"]),
              sealed["schema_version"] == .number(1), value.allSatisfy({ sealed[$0.key] == $0.value }) else { throw ARLError(code:"payload_binding_mismatch") }
        return value
    }
    public func submit(rawRequest: Data, descriptor: ARLResearchDescriptor, epoch: Int,
                       provider: String, modelFingerprint: String, priority: String = "explicit",
                       deadlineMilliseconds: Int = 60_000,
                       onPayloadCreated: (@Sendable (ARLResearchPayloadRecord) async throws -> Void)? = nil) async throws -> ARLResearchSubmission {
        guard (1...524_288).contains(rawRequest.count), descriptor.requestBytes == rawRequest.count,
              descriptor.requestDigest == Self.digest(rawRequest), (0...2_147_483_647).contains(epoch) else { throw ARLError(code:"descriptor_mismatch") }
        let meta=try JSONEncoder().encode(ARLJSON.object(descriptor.wire))
        guard meta.count<=32_768 else { throw ARLError(code:"descriptor_too_large") }
        var created: [String] = []
        do {
            let request=try await upload(rawRequest,purpose:"tisra.research.request.v1",run:descriptor.executionID,epoch:epoch,created:&created,onPayloadCreated:onPayloadCreated)
            let metadata=try await upload(meta,purpose:"tisra.research.descriptor.v1",run:descriptor.executionID,epoch:epoch,created:&created,onPayloadCreated:onPayloadCreated)
            try Task.checkCancellation()
            let params: [String:ARLJSON] = ["schema_version":.number(1),"run_id":.string(descriptor.executionID.uuidString.lowercased()),"epoch":.number(Double(epoch)),"request":.object(request),"descriptor":.object(metadata),"provider":.string(provider),"model":.string(descriptor.model),"model_fingerprint":.string(modelFingerprint),"request_format":.string("openai.responses.request.v1"),"output_format":.string("openai.responses.envelope.v1"),"history_version":.string("openai.responses.history.v1"),"max_output_tokens":.number(Double(descriptor.maximumOutputTokens)),"priority":.string(priority),"deadline_ms":.number(Double(deadlineMilliseconds))]
            let result: ARLJSON
            do { result=try await rpc("research.submit.v1",params) }
            catch let error as ARLError where error.code == "disconnected" { try Task.checkCancellation(); result=try await rpc("research.submit.v1",params) }
            try Task.checkCancellation()
            return ARLResearchSubmission(receipt:try checked(result,params),params:params)
        } catch {
            try await cleanupPayloads(created)
            throw error
        }
    }
    private func checked(_ value: ARLJSON, _ params: [String:ARLJSON], job: String? = nil, authEpoch: String? = nil) throws -> ARLResearchReceipt {
        guard case .object(let fields)=value, Set(fields.keys)==Self.receiptKeys else { throw ARLError(code:"research_receipt_mismatch") }
        let r: ARLResearchReceipt
        do { r=try JSONDecoder().decode(ARLResearchReceipt.self,from:JSONEncoder().encode(value)) }
        catch { throw ARLError(code:"research_receipt_mismatch") }
        guard r.schema_version==1, r.owner==owner, Self.canonicalUUID(r.job_id), Self.canonicalUUID(r.run_id), Self.hash(r.request_sha256),
              Self.states.contains(r.state), ["unknown","not_started"].contains(r.external_stop),
              (1...200).contains(r.auth_epoch.count), !r.auth_epoch.unicodeScalars.contains(where: { $0.value<32 }),
              job == nil || r.job_id==job, authEpoch == nil || r.auth_epoch==authEpoch,
              params["run_id"] == .string(r.run_id), params["epoch"] == .number(Double(r.epoch)),
              params["request"]?["sha256"] == .string(r.request_sha256),
              params["provider"] == .string(r.provider), params["model"] == .string(r.model),
              params["model_fingerprint"] == .string(r.model_fingerprint),
              params["request_format"] == .string(r.request_format), params["output_format"] == .string(r.output_format),
              params["history_version"] == .string(r.history_version) else { throw ARLError(code:"research_receipt_mismatch") }
        if let result=r.result_ref {
            guard case .object(let ref)=fields["result_ref"], Set(ref.keys)==Set(["payload_id","sha256","byte_count"]),
                  Self.canonicalUUID(result.payload_id), Self.hash(result.sha256), (1...1_048_576).contains(result.byte_count) else { throw ARLError(code:"research_receipt_mismatch") }
        }
        let succeeded=r.state=="succeeded"
        guard succeeded == (r.result_ref != nil), !succeeded || (!r.cancel_requested && r.error_code==nil),
              !["queued","running"].contains(r.state) || (!r.cancel_requested && r.error_code==nil),
              r.state != "queued" || r.external_stop=="not_started",
              authPins[r.job_id] == nil || authPins[r.job_id] == r.auth_epoch else { throw ARLError(code:"research_receipt_mismatch") }
        if let error=r.error_code {
            guard (1...100).contains(error.count), !error.unicodeScalars.contains(where: { $0.value<32 }) else { throw ARLError(code:"research_receipt_mismatch") }
        }
        authPins[r.job_id]=r.auth_epoch
        return r
    }
    private func binding(_ r: ARLResearchReceipt) -> [String:ARLJSON] { ["job_id":.string(r.job_id),"run_id":.string(r.run_id),"request_sha256":.string(r.request_sha256),"epoch":.number(Double(r.epoch))] }
    public func status(_ s: ARLResearchSubmission) async throws -> ARLResearchReceipt {
        try checked(await rpc("research.status.v1",binding(s.receipt)),s.params,job:s.receipt.job_id,authEpoch:s.receipt.auth_epoch)
    }
    /// First invalidate local ledger. Ack never proves upstream stop/undo.
    public func cancel(_ s: ARLResearchSubmission) async throws -> ARLResearchReceipt {
        try checked(await rpc("research.cancel.v1",binding(s.receipt)),s.params,job:s.receipt.job_id,authEpoch:s.receipt.auth_epoch)
    }
    public func response(_ s: ARLResearchSubmission) async throws -> Data {
        let current=try await status(s)
        guard current.state=="succeeded", !current.cancel_requested, let p=current.result_ref else { throw ARLError(code:"research_not_completed") }
        var bytes=Data()
        while bytes.count<p.byte_count {
            try Task.checkCancellation()
            let chunk=try await rpc("payload.read.v1",["payload_id":.string(p.payload_id),"offset":.number(Double(bytes.count)),"limit":.number(32_768)])
            guard chunk["payload_id"] == .string(p.payload_id), chunk["sha256"] == .string(p.sha256),
                  chunk["byte_count"] == .number(Double(p.byte_count)), chunk["offset"] == .number(Double(bytes.count)),
                  let encoded=chunk["data_base64"]?.text, let data=Data(base64Encoded:encoded),
                  data.base64EncodedString()==encoded, (1...32_768).contains(data.count), bytes.count+data.count<=p.byte_count else { throw ARLError(code:"payload_binding_mismatch") }
            bytes.append(data)
        }
        guard Self.digest(bytes)==p.sha256 else { throw ARLError(code:"payload_hash_mismatch") }
        let final=try await status(s)
        guard final.state=="succeeded", !final.cancel_requested, final.result_ref==p else { throw ARLError(code:"research_invalidated") }
        try Task.checkCancellation()
        return bytes
    }
}
