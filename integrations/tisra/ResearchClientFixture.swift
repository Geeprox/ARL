// Synthetic injected RPC only. No socket, provider, credentials or product repo.
import Foundation

actor ResearchRPCFixture {
    let scenario: String
    var begins = 0; var writes = 0; var seals = 0; var submits = 0; var statuses = 0; var cancels = 0
    var revokes: [String] = []; var recorded: [ARLResearchPayloadRecord] = []
    var params: [String:ARLJSON] = [:]
    var revokeFailure = true; var revokeWasCancelled = false
    let reply = Data("{\"id\":\"synthetic\"}".utf8)
    init(_ scenario: String) { self.scenario=scenario }
    func persist(_ record: ARLResearchPayloadRecord) throws {
        recorded.append(record)
        if scenario == "persist_failure" { throw ARLError(code:"fixture_persist_failed") }
    }
    func recovered() { revokeFailure=false }
    func receipt(_ state: String = "queued", auth: String = "revision-1") -> ARLJSON {
        let result: ARLJSON = state == "succeeded" ? .object(["payload_id":.string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),"sha256":.string(ARLResearchClient.digest(reply)),"byte_count":.number(Double(reply.count))]) : .null
        var v: [String:ARLJSON] = ["schema_version":.number(1),"job_id":.string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),"owner":.string("tisra"),"run_id":params["run_id"]!,"request_sha256":params["request"]!["sha256"]!,"epoch":params["epoch"]!,"auth_epoch":.string(auth),"state":.string(state),"provider":params["provider"]!,"model":params["model"]!,"model_fingerprint":params["model_fingerprint"]!,"request_format":params["request_format"]!,"output_format":params["output_format"]!,"history_version":params["history_version"]!,"result_ref":result,"error_code":.null,"cancel_requested":.bool(false),"external_stop":.string(state == "queued" ? "not_started" : "unknown")]
        switch scenario {
        case "uppercase_uuid": v["job_id"] = .string("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        case "empty_auth": v["auth_epoch"] = .string("")
        case "success_null": v["state"] = .string("succeeded")
        case "queued_result": v["result_ref"] = .object(["payload_id":.string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),"sha256":.string(ARLResearchClient.digest(reply)),"byte_count":.number(Double(reply.count))])
        default: break
        }
        return .object(v)
    }
    func rpc(_ method: String, _ args: [String:ARLJSON]) throws -> ARLJSON {
        switch method {
        case "payload.begin.v1":
            begins += 1
            if scenario == "lost_begin" { throw ARLError(code:"disconnected") }
            if scenario == "cancel_begin" { withUnsafeCurrentTask { $0?.cancel() } }
            return .object(["schema_version":.number(1),"payload_id":.string(String(format:"00000000-0000-4000-8000-%012d",begins)),"expires_at_ms":.number(1_900_000_000_000),"chunk_bytes":.number(scenario == "second_begin_bad" && begins == 2 ? 1 : 8192)])
        case "payload.write.v1":
            writes += 1
            if scenario == "cancel_write" { withUnsafeCurrentTask { $0?.cancel() }; throw ARLError(code:"disconnected") }
            return .object(["schema_version":.number(1),"accepted_index":args["index"]!])
        case "payload.seal.v1":
            seals += 1
            if scenario == "cancel_seal" { withUnsafeCurrentTask { $0?.cancel() } }
            if scenario == "cleanup_pending" && seals == 2 { throw ARLError(code:"disconnected") }
            return .object(args.merging(["schema_version":.number(1)]) { _,new in new })
        case "payload.revoke.v1":
            let id=args["payload_id"]!.text!;revokes.append(id)
            revokeWasCancelled = revokeWasCancelled || Task.isCancelled
            if scenario == "cleanup_pending" && revokeFailure && id.hasSuffix("000001") { throw ARLError(code:"disconnected") }
            return .object(["schema_version":.number(1),"revoked":.bool(true),"external_stop":.string("unknown")])
        case "research.submit.v1":
            submits += 1; params=args
            if scenario == "lost_submit" { throw ARLError(code:"disconnected") }
            return receipt()
        case "research.status.v1":
            statuses += 1
            if scenario == "read_drift" { return receipt("succeeded",auth:statuses == 1 ? "revision-1" : "revision-2") }
            if scenario == "restore_read" { return receipt("succeeded") }
            return receipt(auth: ["status_drift", "restore_status_drift"].contains(scenario) ? "revision-2" : "revision-1")
        case "research.cancel.v1":
            cancels += 1
            return receipt(auth: scenario == "restore_cancel" ? "revision-1" : "revision-2")
        case "payload.read.v1":
            return .object(["schema_version":.number(1),"payload_id":.string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),"sha256":.string(ARLResearchClient.digest(reply)),"byte_count":.number(Double(reply.count)),"offset":.number(0),"data_base64":.string(reply.base64EncodedString()),"eof":.bool(true)])
        default: throw ARLError(code:"unknown_method")
        }
    }
    func summary(_ status: String) -> ARLJSON {
        .object(["status":.string(status),"begins":.number(Double(begins)),"writes":.number(Double(writes)),"submits":.number(Double(submits)),"statuses":.number(Double(statuses)),"cancels":.number(Double(cancels)),"revokes":.number(Double(revokes.count)),"recorded":.number(Double(recorded.count)),"revoke_task_cancelled":.bool(revokeWasCancelled),"provider_calls":.number(0)])
    }
    func restoreFixtureParams(_ p: [String: ARLJSON]) { params = p }
}

@main struct ResearchClientFixtureMain {
    static func main() async throws {
        let scenario=CommandLine.arguments[1], fixture=ResearchRPCFixture(CommandLine.arguments[1])
        let client=ARLResearchClient(fixtureOwner:scenario == "restore_wrong_owner" ? "other" : "tisra",exchange:{ try await fixture.rpc($0,$1) })
        let raw=Data("{\"synthetic\":true}".utf8)
        let descriptor=ARLResearchDescriptor(executionID:UUID(),threadID:UUID(),sequence:0,model:"fixture-model",requestDigest:ARLResearchClient.digest(raw),requestBytes:raw.count,evidence:[])
        var status="ok"
        do {
            if scenario.hasPrefix("restore_") {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
                if let wire = try? JSONDecoder().decode(ARLJSON.self, from: data), case .object(let p) = wire["params"] {
                    await fixture.restoreFixtureParams(p) // server double only, no consumer acceptance
                }
                let restored = try await client.restoreSubmission(from: data, expectedSHA256: CommandLine.arguments[3])
                guard restored.receipt.auth_epoch == "revision-1" else { throw ARLError(code:"fixture_original_auth_lost") }
                if scenario == "restore_pin_conflict" {
                    guard case .object(var record) = try JSONDecoder().decode(ARLJSON.self, from: data),
                          case .object(var receipt) = record["receipt"] else { throw ARLError(code:"fixture_bad_record") }
                    receipt["auth_epoch"] = .string("revision-2"); record["receipt"] = .object(receipt)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let changed = try encoder.encode(ARLJSON.object(record))
                    _ = try await client.restoreSubmission(from: changed, expectedSHA256: ARLResearchClient.digest(changed))
                } else if ["restore_cancel", "restore_cancel_drift"].contains(scenario) {
                    _ = try await client.cancel(restored)
                } else if scenario == "restore_read" { _ = try await client.response(restored) }
                else if ["restore_status", "restore_status_drift"].contains(scenario) { _ = try await client.status(restored) }
                print(String(decoding:try JSONEncoder().encode(await fixture.summary(status)),as:UTF8.self))
                return
            }
            let submission=try await client.submit(rawRequest:raw,descriptor:descriptor,epoch:0,provider:"fixture",modelFingerprint:"fixture-revision",onPayloadCreated:{ try await fixture.persist($0) })
            if scenario == "save_record" {
                try submission.durableRecord().write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            }
            if scenario == "status_drift" { _ = try await client.status(submission) }
            if scenario == "cancel_drift" { _ = try await client.cancel(submission) }
            if scenario == "read_drift" { _ = try await client.response(submission) }
        } catch let pending as ARLResearchCleanupPending {
            status="payload_cleanup_pending"
            guard pending.payloadIDs.count==1 else { throw ARLError(code:"fixture_wrong_pending_count") }
            await fixture.recovered();try await client.cleanupPayloads(pending.payloadIDs)
        } catch is CancellationError { status="cancelled" }
        catch let error as ARLError { status=error.code }
        print(String(decoding:try JSONEncoder().encode(await fixture.summary(status)),as:UTF8.self))
    }
}
