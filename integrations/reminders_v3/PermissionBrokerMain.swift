import Foundation
import AppKit

// Concrete source-only native embedding. The library methods for permission
// request and reviewed operations are linked into THIS executable, which owns
// EventKit/TCC. CLI only exposes bounded status; no prompt/effect/authority CLI.
@main struct ARLRemindersV3PermissionBroker {
    @MainActor static func main() throws {
        let args=Array(CommandLine.arguments.dropFirst())
        if args.count==2,args[0]=="--serve-approved" {
            do {
                // A disabled/invalid entry must stop before AppKit tries to
                // register this process with the window system. The host repeats
                // this exact sealed policy check before constructing EventKit.
                _ = try RemindersFirstPolicy.sealed(args[1])
                #if !REMINDERS_FIRST_SLICE_FIXTURE
                _ = NSApplication.shared
                #endif
                try runRemindersFirstHost(policyPath:args[1])
            }
            catch{let code=(error as? RemindersTransportFault)?.code ?? "host_unavailable";print("{\"schema_version\":1,\"status\":\"stopped\",\"code\":\"\(code)\",\"prompts_requested\":false}");exit(2)}
            return
        }
        guard Array(CommandLine.arguments.dropFirst()) == ["--permissions-status"] else {
            print("{\"schema_version\":1,\"status\":\"controlled_host_required\",\"prompts_requested\":false,\"effects_started\":0}")
            return
        }
        let identity=try NativePermissionIdentity.current(expectedBundle:RemindersV3PermissionIntegration.responsibleBundleID)
        let records=try RemindersV3PermissionIntegration.capabilityIDs.sorted().map { capability in
            try JSONDecoder().decode(Record.self,from:RemindersV3PermissionIntegration.permissionSnapshot(capabilityID:capability))
        }
        struct Family:Encodable { let schema_version=1;let identity:NativePermissionIdentity;let records:[Record] }
        print(String(decoding:try JSONEncoder().encode(Family(identity:identity,records:records)),as:UTF8.self))
    }
    // Uses a separate Decodable shape so immutable native evidence constants are
    // not silently ignored while adapting the exact ten operation records.
    struct Record:Codable {
        let schema_version:Int;let capability_id:String;let identity:NativePermissionIdentity
        let permission_state:String;let observed_at_ms:Int64;let preflight_code:String
        let prompts_requested:Bool;let data_read:Bool;let access_evidence:String
    }
}
