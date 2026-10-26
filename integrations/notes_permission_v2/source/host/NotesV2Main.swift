import Foundation
@main enum NotesV2Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--configuration"] {
            // Inert self-observation only. No profile, native Notes surface or
            // permission API is constructed/reached through this branch.
            do {
                var value = try NotesV2ObservedIdentity.inspectConfiguration(Bundle.main.executableURL!)
                value["runtime_bundle_usage_description"] = Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String ?? ""
                value["identity"] = try NotesV2ObservedIdentity.inspect(Bundle.main.executableURL!).object
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
                FileHandle.standardOutput.write(Data([10]))
            } catch { status("configuration_unavailable") }
            return
        }
        if args == ["--serve-controlled-v2"] || args == ["--serve-permissions-controlled-v2"] {
            let permissionSetup = args == ["--serve-permissions-controlled-v2"]
            // Apple's API may block arbitrarily during consent and explicitly
            // forbids the main thread. Normal ask=false checks use this worker too.
            DispatchQueue.global(qos: .userInitiated).async {
                do { try NotesV2Bootstrap.run(permissionSetup: permissionSetup) }
                catch let fault as NativeFault { status(fault.code, serving: true, permissionSetup: permissionSetup) }
                catch let fault as ReviewFault { status(fault.code, serving: true, permissionSetup: permissionSetup) }
                catch { status("host_unavailable", serving: true, permissionSetup: permissionSetup) }
                exit(0)
            }
            dispatchMain()
        }
        status("host_disabled")
    }
    static func status(_ code: String, serving: Bool = false, permissionSetup: Bool = false) {
        let guaranteedInert = NotesV2Profile.synthetic || !serving || ["host_disabled", "profile_invalid"].contains(code)
        let value: [String: Any] = ["schema_version": 2, "state": code, "host_mode": NotesV2Profile.synthetic ? "synthetic" : "notes",
            "identity": NotesV2CodePin.signingIdentifier,
            "profile_sha256": permissionSetup ? NotesV2BuildSeal.permissionProfileHash : NotesV2BuildSeal.profileHash,
            "source_closure_sha256": NotesV2BuildSeal.sourceHash,
            "notes_events_sent": guaranteedInert ? 0 : NSNull(), "permission_queries": guaranteedInert ? 0 : NSNull(),
            "write_outcome": guaranteedInert ? "no_effect" : "unknown",
            "permission_prompts_requested": guaranteedInert ? 0 : NSNull(), "permission_request_source_implemented": true,
            "append_enabled": false, "attachment_write_enabled": false]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
}
