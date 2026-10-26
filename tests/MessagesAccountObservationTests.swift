import Foundation
import ApplicationServices

// The transport models the independent review's real A→B→A ordering bug.
// It supports both legacy per-property reads and coherent pALL responses, so
// the same fixture rejects the old production backend instead of faking a pass.
@main enum MessagesAccountObservationTests {
    enum Failure: Error { case assertion(String), unexpectedEvent }
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure.assertion(label) }; checks += 1
    }
    static func record(_ id: String) -> NSAppleEventDescriptor {
        let value = NSAppleEventDescriptor.record()
        value.setDescriptor(.init(string: id), forKeyword: 0x49442020)
        value.setDescriptor(.init(string: id == "A" ? "Synthetic SMS A" : "Synthetic iMessage B"), forKeyword: 0x6d73646e)
        value.setDescriptor(.init(enumCode: id == "A" ? 0x73736d73 : 0x73696d73), forKeyword: 0x73747970)
        value.setDescriptor(.init(boolean: true), forKeyword: 0x656e626c)
        value.setDescriptor(.init(enumCode: 0x636f6e6e), forKeyword: 0x73737461)
        value.setDescriptor(.init(typeCode: 0x69637376), forKeyword: 0x70636c73)
        return value
    }
    final class Transport {
        let aba: Bool
        var shifted = false, firstMetadata: UInt32 = 0
        var snapshots = 0, individualAccountFields = 0, sends = 0
        var unavailable = false, corruptStableID = false
        var corrupt: ((NSAppleEventDescriptor) -> NSAppleEventDescriptor)?
        init(aba: Bool) { self.aba = aba }
        func call(_ cls: UInt32, _ event: UInt32, _ params: [UInt32: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
            if cls != 0x636f7265 { sends += 1; throw Failure.unexpectedEvent }
            if event == 0x636e7465 { return .init(int32: 2) }
            guard event == 0x67657464, let prop = params[0x2d2d2d2d], let ref = prop.forKeyword(0x66726f6d),
                  let code = prop.forKeyword(0x73656c64)?.typeCodeValue else { throw Failure.unexpectedEvent }
            let kind = ref.forKeyword(0x77616e74)?.typeCodeValue
            if kind == 0x70726573 {
                if code == 0x49442020 { return .init(string: "synthetic-participant") }
                if code == 0x686e646c { return .init(string: "review@example.test") }
                throw Failure.unexpectedEvent
            }
            // A participant's account property resolves to the truthful A.
            if kind == 0x70726f70 && code == 0x49442020 { return .init(string: "A") }
            guard kind == 0x69637376 else { throw Failure.unexpectedEvent }
            let indexed = ref.forKeyword(0x666f726d)?.enumCodeValue == 0x696e6478
            let index = indexed ? Int(ref.forKeyword(0x73656c64)!.int32Value) : 0
            if code == 0x70414c4c {
                snapshots += 1
                if unavailable { throw AppleDirectFault("automation_failed", nativeStatus: -10000) }
                // Reordering during this event changes the entire resolved
                // account observation, including its ID, never selected fields.
                let id = indexed ? (aba && index == 1 ? "B" : index == 1 ? "A" : "B") :
                    (corruptStableID ? "B" : ref.forKeyword(0x73656c64)!.stringValue!)
                let value = record(id)
                return corrupt?(value) ?? value
            }
            individualAccountFields += 1
            if !indexed {
                guard code == 0x49442020 else { throw Failure.unexpectedEvent }
                return .init(string: ref.forKeyword(0x73656c64)!.stringValue!)
            }
            if aba && index == 1 && code != 0x49442020 && !shifted { shifted = true; firstMetadata = code }
            let id = shifted ? (index == 1 ? "B" : "A") : (index == 1 ? "A" : "B")
            guard let value = record(id).forKeyword(code) else { throw Failure.unexpectedEvent }
            if aba && index == 1 && shifted &&
                ((firstMetadata == 0x73747970 && code == 0x6d73646e) || (firstMetadata == 0x6d73646e && code == 0x73737461)) {
                shifted = false; firstMetadata = 0
            }
            return value
        }
        var backend: MessagesDirectBackend { .init(send: call, check: {}) }
    }
    static func main() throws {
        let baseline = Transport(aba: false)
        let baselineScan = try baseline.backend.accounts()
        try expect(baselineScan.accounts.map(\.id) == ["B"] && baselineScan.excluded == 1, "baseline admits only actual iMessage B")
        let aba = Transport(aba: true)
        do {
            let scan = try aba.backend.accounts()
            try expect(!scan.accounts.contains(where: { $0.id == "A" }), "ABA cannot admit SMS A as iMessage")
        } catch let error as AppleDirectFault {
            try expect(["ambiguous_account", "target_changed"].contains(error.code), "ABA repeated coherent ID is rejected")
        }
        try expect(aba.snapshots > 0 && aba.individualAccountFields == 0, "account metadata never uses separate indexed property events")
        let selection = Transport(aba: true)
        let forged = MessagesDirectAccount(id: "A", label: "Synthetic iMessage B")
        let recipient = MessagesDirectRecipient(account: forged, id: "synthetic-participant", handle: "review@example.test", expires: Date().addingTimeInterval(100))
        do { _ = try selection.backend.verify(recipient); throw Failure.assertion("ABA forged A passed recipient verification") }
        catch let error as AppleDirectFault { try expect(error.code == "account_changed", "selected A is rejected from its own SMS observation") }
        try expect(selection.snapshots == 1 && selection.individualAccountFields == 0, "selection validates ID and all metadata in one stable observation")
        let unavailable = Transport(aba: false); unavailable.unavailable = true
        let failed = try unavailable.backend.accounts()
        try expect(failed.accounts.isEmpty && failed.failures.count == 2 && failed.failures.allSatisfy {
            $0.fault.nativeStatus == -10000 && $0.fault.step == .messagesIndexedMetadata
        }, "unsupported whole-account observation remains diagnostic-only")
        do { _ = try unavailable.backend.verify(recipient); throw Failure.assertion("unsupported stable observation accepted") }
        catch let error as AppleDirectFault {
            try expect(error.nativeStatus == -10000 && error.step == .messagesStableMetadata,
                       "unavailable stable metadata keeps its exact selector diagnostic and blocks recipient validation")
        }
        let wrongID = Transport(aba: false); wrongID.corruptStableID = true
        do { _ = try wrongID.backend.verify(recipient); throw Failure.assertion("wrong response ID accepted") }
        catch let error as AppleDirectFault { try expect(error.code == "account_changed", "stable reply must contain the selected ID") }
        for mutate in [
            { (value: NSAppleEventDescriptor) in value.setDescriptor(.init(string: "iMessage"), forKeyword: 0x73747970); return value },
            { (value: NSAppleEventDescriptor) in value.setDescriptor(.init(int32: 1), forKeyword: 0x656e626c); return value },
            { (value: NSAppleEventDescriptor) in value.setDescriptor(.init(typeCode: 0x63686174), forKeyword: 0x70636c73); return value },
            { (_: NSAppleEventDescriptor) in NSAppleEventDescriptor.list() }
        ] {
            let invalid = Transport(aba: false); invalid.corrupt = mutate
            let scan = try invalid.backend.accounts()
            try expect(scan.accounts.isEmpty && scan.failures.count == 2, "incomplete or wrongly typed metadata cannot become usable")
        }
        try expect([baseline, aba, selection, unavailable, wrongID].allSatisfy { $0.sends == 0 }, "review regression sends zero messages")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"ABA_scan_and_selected_recipient\":true,\"actual_os_or_messages_calls\":false,\"send_events\":0}")
    }
}
