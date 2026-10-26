import Foundation

// The candidate has NO production caller registration, target or grant. Direct
// launch cannot turn stdin/flags into authority, request TCC or save a note.
// NotesHostConnection is consumed by a reviewed controlled parent composition;
// that startup composition is intentionally not enabled by this source build.
@main struct ARLNotesBridgeMain {
    @MainActor static func main() throws {
        if CommandLine.arguments.dropFirst() == ["--serve-controlled"] {
            do { try NotesControlledBootstrap.run() }
            catch let fault as ReviewFault {
                let safe = ["host_disabled", "profile_invalid", "caller_unverified", "approval_expired"]
                print(safe.contains(fault.code) ? fault.code : "host_unavailable")
            } catch { print("host_unavailable") }
            return
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || arguments == ["--status"] || arguments == ["--help"] else {
            print("unconfigured_host"); return
        }
        let status: [String: Any] = ["schema_version": 1, "helper_id": "local.arl.notesbridge",
            "state": "disabled", "caller_registration": "not_configured", "target": "not_registered",
            "effect_grants": false, "permission": "not_checked", "notes_calls": 0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]), as: UTF8.self))
    }
}
