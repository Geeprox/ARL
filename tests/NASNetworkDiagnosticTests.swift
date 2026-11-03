import Foundation
import ARLCredentialOnboarding

@main enum NASNetworkDiagnosticTests {
    final class Counter: @unchecked Sendable {
        private let lock=NSLock();private var count=0
        func increment(){lock.withLock{count+=1}}
        var value:Int{lock.withLock{count}}
    }
    static func sample(_ outcome:NASNetworkDiagnostic.Outcome)->NASNetworkDiagnostic.Snapshot {
        .init(at:1,outcome:outcome,unsatisfied_reason:.localNetworkDenied,
            error_domain:.posix,error_code:65,elapsed_milliseconds:1)
    }
    static func main() async throws {
        let config=try NASConnectionConfiguration(sourceRef:"fixture",host:"secret-endpoint.invalid",share:"home",root:"ARL-Test")
        precondition(NASNetworkDiagnostic.seconds>0 && NASNetworkDiagnostic.seconds<3)
        precondition(NASNetworkDiagnostic.eligible(NASRuntimeFailure.transportFailed,configuration:config))
        precondition(!NASNetworkDiagnostic.eligible(NASRuntimeFailure.timeout,configuration:config))
        let wrong=try NASConnectionConfiguration(sourceRef:"fixture",host:"secret-endpoint.invalid",share:"private",root:"ARL-Test")
        precondition(!NASNetworkDiagnostic.eligible(NASRuntimeFailure.transportFailed,configuration:wrong))
        var checks=4
        let raw=try JSONEncoder().encode(sample(.failed))
        let fields=try JSONSerialization.jsonObject(with:raw) as! [String:Any]
        precondition(Set(fields.keys)==["schema_version","operation","context","credentials_read","smb_payload_sent","at","outcome","unsatisfied_reason","error_domain","error_code","elapsed_milliseconds"])
        precondition(!String(decoding:raw,as:UTF8.self).contains(config.host))
        precondition(fields["credentials_read"] as? Bool==false && fields["smb_payload_sent"] as? Bool==false)
        if CommandLine.arguments.count==2 {
            let path=URL(fileURLWithPath:CommandLine.arguments[1])
            try raw.write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        checks += 1
        let early=NASNetworkDiagnostic.Completion()
        precondition(early.resolve(sample(.cancelled)))
        precondition(!early.resolve(sample(.ready)))
        let cancelled=await withCheckedContinuation { early.wait($0) }
        precondition(cancelled.outcome == .cancelled);checks += 1
        let racing=NASNetworkDiagnostic.Completion(),wins=Counter()
        let waiting=Task { await withCheckedContinuation { racing.wait($0) } }
        await withTaskGroup(of:Void.self) { group in
            for outcome in [NASNetworkDiagnostic.Outcome.ready,.deadline,.cancelled] {
                group.addTask {if racing.resolve(sample(outcome)){wins.increment()}}
            }
        }
        _=await waiting.value
        precondition(wins.value==1);checks += 1
        // Cancellation is set before capture, so this never creates or starts
        // an NWConnection. A fixture must not prompt for network permission.
        let held=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await NASNetworkDiagnostic.capture(configuration:config)
        }
        let skipped=await held.value
        precondition(skipped.outcome == .cancelled && skipped.elapsed_milliseconds==0);checks += 1
        let report=try JSONSerialization.data(withJSONObject:["status":"PASS","checks":checks,
            "real_network_calls":0,"keychain_calls":0,"nas_writes":0],options:[.sortedKeys])
        print(String(decoding:report,as:UTF8.self))
    }
}
