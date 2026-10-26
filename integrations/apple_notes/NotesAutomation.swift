import Foundation
import ApplicationServices
import CoreGraphics

// Local Notes.sdef/CocoaStandard.sdef codes. String values are descriptors,
// never executable AppleScript, shell source, or application identifiers.
enum NotesAppleEvents {
    static let core: UInt32 = 0x636f7265
    static let get: UInt32 = 0x67657464
    static let make: UInt32 = 0x6372656c
    static let note: UInt32 = 0x6e6f7465
    static let account: UInt32 = 0x61636374
    static let folder: UInt32 = 0x63666f6c
    static let id: UInt32 = 0x49442020
    static let name: UInt32 = 0x706e616d
    static let body: UInt32 = 0x626f6479
    static let shared: UInt32 = 0x73687264
    static let direct: UInt32 = 0x2d2d2d2d
    static let errorNumber: UInt32 = 0x6572726e
    static let want: UInt32 = 0x77616e74
    static let from: UInt32 = 0x66726f6d
    static let form: UInt32 = 0x666f726d
    static let selector: UInt32 = 0x73656c64
    static let property: UInt32 = 0x70726f70
    static let objectSpecifier: UInt32 = 0x6f626a20

    static func object(_ kind: UInt32, id: String, container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(kind, form: Self.id, key: NSAppleEventDescriptor(string: id), container: container)
    }
    private static func specifier(_ kind: UInt32, form: UInt32, key: NSAppleEventDescriptor, container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let r = NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode: kind), forKeyword: want)
        r.setDescriptor(container, forKeyword: from)
        r.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: Self.form)
        r.setDescriptor(key, forKeyword: selector)
        guard let descriptor = r.coerce(toDescriptorType: objectSpecifier) else { throw ReviewFault("automation_encoding_failed") }
        return descriptor
    }
    static func folderReference(_ b: NotesFolderBinding) throws -> NSAppleEventDescriptor {
        let account = try object(Self.account, id: b.accountID, container: .null())
        return try object(folder, id: b.folderID, container: account)
    }
    static func event(_ eventID: UInt32) -> NSAppleEventDescriptor {
        // Fixed system application URL; no caller-supplied bundle ID/path.
        NSAppleEventDescriptor(eventClass: core, eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app")),
            returnID: -1, transactionID: 0)
    }
    static func readProperty(_ code: UInt32, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let e = event(get)
        let p = try propertyReference(code, of: container)
        e.setParam(p, forKeyword: direct)
        return e
    }
    static func propertyReference(_ code: UInt32, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(property, form: property, key: NSAppleEventDescriptor(typeCode: code), container: container)
    }
    static func createEvent(_ p: NotesCreateProposal, binding: NotesFolderBinding) throws -> NSAppleEventDescriptor {
        try binding.validate()
        let e = event(make)
        e.setParam(NSAppleEventDescriptor(typeCode: note), forKeyword: 0x6b6f636c) // kocl: new class
        e.setParam(try folderReference(binding), forKeyword: 0x696e7368) // insh: at exactly this folder
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(string: p.title), forKeyword: name)
        properties.setDescriptor(NSAppleEventDescriptor(string: p.html), forKeyword: body)
        e.setParam(properties, forKeyword: 0x70726474) // prdt: initial properties only
        return e
    }
    static func decodeReply(_ reply: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        if let error = reply.paramDescriptor(forKeyword: errorNumber), error.int32Value != 0 {
            switch error.int32Value {
            case -1743, -1744: throw ReviewFault("needs_permission")
            case -1728: throw ReviewFault("target_unavailable")
            case -1712: throw ReviewFault("automation_timeout")
            default: throw ReviewFault("automation_failed")
            }
        }
        guard let value = reply.paramDescriptor(forKeyword: direct) else { throw ReviewFault("invalid_automation_reply") }
        return value
    }
}

// Source-only real adapter. Constructing it does not query permission or Notes.
// Build/tests never call these effect methods against the real application.
final class NativeNotesEffects: NotesEffects {
    // Future explicit first-use setup only, after existing Automation consent.
    // Reads the default account/folder metadata, not all accounts/folders or any
    // note. Candidate still needs user confirmation + trusted host persistence;
    // this method cannot register a grant. Never called in development/tests.
    func defaultFolderCandidate(alias: String, deadline: Double) throws -> NotesFolderBinding {
        guard identifier(alias) else { throw ReviewFault("invalid_target_registration") }
        guard permission() == "authorized" else { throw ReviewFault("needs_permission") }
        guard lockState() == "unlocked" else { throw ReviewFault("needs_unlock") }
        let account = try NotesAppleEvents.propertyReference(0x64666163, of: .null()) // dfac
        let folder = try NotesAppleEvents.propertyReference(0x64666f6c, of: account) // dfol
        let a = try send(NotesAppleEvents.readProperty(NotesAppleEvents.id, of: account), deadline: deadline)
        let f = try send(NotesAppleEvents.readProperty(NotesAppleEvents.id, of: folder), deadline: deadline)
        let n = try send(NotesAppleEvents.readProperty(NotesAppleEvents.name, of: folder), deadline: deadline)
        let s = try send(NotesAppleEvents.readProperty(NotesAppleEvents.shared, of: folder), deadline: deadline)
        guard let accountID = a.stringValue, let folderID = f.stringValue, let name = n.stringValue,
              s.descriptorType == typeBoolean, !s.booleanValue else { throw ReviewFault("invalid_target_registration") }
        let binding = NotesFolderBinding(alias: alias, accountID: accountID, folderID: folderID, expectedName: name)
        try binding.validate()
        let exact = try resolve(binding, deadline: deadline)
        guard exact.accountID == accountID, exact.folderID == folderID, exact.name == name, !exact.shared else { throw ReviewFault("target_changed") }
        return binding
    }
    func permission() -> String {
        let target = NSAppleEventDescriptor(applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))
        for event in [NotesAppleEvents.get, NotesAppleEvents.make] {
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, NotesAppleEvents.core, event, false)
            switch status {
            case noErr: continue
            case -1744: return "not_determined"
            case -1743: return "denied"
            default: return "unknown"
            }
        }
        return "authorized"
    }
    func lockState() -> String {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = session["CGSSessionScreenIsLocked"] as? Bool else { return "unknown" }
        return locked ? "locked" : "unlocked"
    }
    private func send(_ event: NSAppleEventDescriptor, deadline: Double) throws -> NSAppleEventDescriptor {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ReviewFault("approval_expired") }
        // Never prompt, switch/activate UI, or record the event. These options
        // also fail closed if permission disappears after the readiness read.
        let options = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent))
        do {
            let reply = try event.sendEvent(options: options, timeout: min(5, remaining))
            return try NotesAppleEvents.decodeReply(reply)
        } catch let e as ReviewFault { throw e }
        catch let e as NSError {
            switch e.code {
            case -1743, -1744: throw ReviewFault("needs_permission")
            case -1712: throw ReviewFault("automation_timeout")
            default: throw ReviewFault("automation_failed")
            }
        }
    }
    func resolve(_ b: NotesFolderBinding, deadline: Double) throws -> NotesTargetMetadata {
        try b.validate()
        let account = try NotesAppleEvents.object(NotesAppleEvents.account, id: b.accountID, container: .null())
        let folder = try NotesAppleEvents.folderReference(b)
        // Four property reads of just the registered account/folder. No all
        // accounts/folders/notes fetch, body/plaintext/attachment or default.
        let accountID = try send(NotesAppleEvents.readProperty(NotesAppleEvents.id, of: account), deadline: deadline)
        let folderID = try send(NotesAppleEvents.readProperty(NotesAppleEvents.id, of: folder), deadline: deadline)
        let name = try send(NotesAppleEvents.readProperty(NotesAppleEvents.name, of: folder), deadline: deadline)
        let shared = try send(NotesAppleEvents.readProperty(NotesAppleEvents.shared, of: folder), deadline: deadline)
        guard let a = accountID.stringValue, let f = folderID.stringValue, let n = name.stringValue,
              shared.descriptorType == typeBoolean else { throw ReviewFault("invalid_automation_reply") }
        return NotesTargetMetadata(accountID: a, folderID: f, name: n, shared: shared.booleanValue)
    }
    func create(_ p: NotesCreateProposal, binding: NotesFolderBinding, deadline: Double) throws -> String {
        let event = try NotesAppleEvents.createEvent(p, binding: binding)
        guard Int64(Date().timeIntervalSince1970 * 1000) < p.expiresAtMS else { throw ReviewFault("approval_expired") }
        let result = try send(event, deadline: deadline)
        // CocoaStandard declares a specifier result. No follow-up fetch of
        // note ID/content, no replay if Notes fails to return this receipt.
        guard result.descriptorType == NotesAppleEvents.objectSpecifier else { throw ReviewFault("invalid_automation_reply") }
        return "created_local"
    }
}
