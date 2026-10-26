import Foundation
import ApplicationServices
import CryptoKit

struct NativeFault: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

enum NotesRequestIO {
    static func read(maximum: Int = 12 * 1024 * 1024, take: (Int) throws -> Data) throws -> Data {
        var data = Data()
        while true {
            // Pipes may return a partial chunk before EOF. Never try to decode
            // a single read as the full attachment/request JSON frame.
            let chunk = try take(min(65536, maximum + 1 - data.count))
            if chunk.isEmpty { return data }
            data.append(chunk)
            guard data.count <= maximum else { throw NativeFault("invalid_arguments") }
        }
    }
}

// Codes reviewed against local Notes.sdef and CocoaStandard.sdef. Inputs are
// descriptors, never AppleScript/shell text. No set-body event exists here.
enum NotesEvents {
    static let core: UInt32 = 0x636f7265, get: UInt32 = 0x67657464, make: UInt32 = 0x6372656c
    static let count: UInt32 = 0x636e7465, save: UInt32 = 0x73617665
    static let note: UInt32 = 0x6e6f7465, account: UInt32 = 0x61636374, folder: UInt32 = 0x63666f6c, attachment: UInt32 = 0x61747473
    static let id: UInt32 = 0x49442020, name: UInt32 = 0x706e616d, body: UInt32 = 0x626f6479, plaintext: UInt32 = 0x74657874
    static let modified: UInt32 = 0x61736d6f, shared: UInt32 = 0x73687264, password: UInt32 = 0x70777072, container: UInt32 = 0x636e7472
    static let direct: UInt32 = 0x2d2d2d2d, want: UInt32 = 0x77616e74, from: UInt32 = 0x66726f6d, form: UInt32 = 0x666f726d, selector: UInt32 = 0x73656c64

    static func specifier(_ kind: UInt32, form: UInt32, key: NSAppleEventDescriptor, in parent: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: kind), forKeyword: want)
        record.setDescriptor(parent, forKeyword: from)
        record.setDescriptor(.init(enumCode: form), forKeyword: Self.form)
        record.setDescriptor(key, forKeyword: selector)
        guard let value = record.coerce(toDescriptorType: 0x6f626a20) else { throw NativeFault("encoding_failed") }
        return value
    }
    static func object(_ kind: UInt32, id: String, in parent: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        try specifier(kind, form: Self.id, key: .init(string: id), in: parent)
    }
    static func indexed(_ kind: UInt32, index: Int, in parent: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(kind, form: 0x696e6478, key: .init(int32: Int32(index)), in: parent)
    }
    static func all(_ kind: UInt32, in parent: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(kind, form: 0x696e6478, key: .init(enumCode: 0x616c6c20), in: parent)
    }
    static func property(_ code: UInt32, of object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(0x70726f70, form: 0x70726f70, key: .init(typeCode: code), in: object)
    }
    static func event(_ eventID: UInt32) -> NSAppleEventDescriptor {
        .init(eventClass: core, eventID: eventID,
              targetDescriptor: .init(applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app")),
              returnID: -1, transactionID: 0)
    }
    static func read(_ code: UInt32, of object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = event(get)
        event.setParam(try property(code, of: object), forKeyword: direct)
        return event
    }
    static func create(title: String, html: String, at folder: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = event(make)
        event.setParam(.init(typeCode: note), forKeyword: 0x6b6f636c)
        event.setParam(folder, forKeyword: 0x696e7368)
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(.init(string: title), forKeyword: name)
        properties.setDescriptor(.init(string: html), forKeyword: body)
        event.setParam(properties, forKeyword: 0x70726474)
        return event
    }
    static func attach(file: URL, at note: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = event(make)
        event.setParam(.init(typeCode: attachment), forKeyword: 0x6b6f636c)
        event.setParam(note, forKeyword: 0x696e7368)
        // The dictionary's hidden file contents maps to make ... with data
        // (CocoaStandard kAESetData = data). No new body is supplied.
        event.setParam(NSAppleEventDescriptor(fileURL: file), forKeyword: 0x64617461)
        return event
    }
    static func export(_ attachment: NSAppleEventDescriptor, to file: URL) -> NSAppleEventDescriptor {
        let event = event(save)
        event.setParam(attachment, forKeyword: direct)
        event.setParam(NSAppleEventDescriptor(fileURL: file), forKeyword: 0x6b66696c)
        return event
    }
    static func namedNotes(_ title: String) throws -> NSAppleEventDescriptor {
        // whose name = exact title, evaluated inside Notes rather than reading
        // every personal note body. Test descriptor is data, not source code.
        guard let examined = NSAppleEventDescriptor(descriptorType: 0x65786d6e, data: Data()) else { throw NativeFault("encoding_failed") }
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(try property(name, of: examined), forKeyword: 0x6f626a31)
        comparison.setDescriptor(.init(string: title), forKeyword: 0x6f626a32)
        comparison.setDescriptor(.init(enumCode: 0x3d202020), forKeyword: 0x72656c6f)
        guard let test = comparison.coerce(toDescriptorType: 0x636d7064) else { throw NativeFault("encoding_failed") }
        return try specifier(note, form: 0x74657374, key: test, in: .null())
    }
}

struct NativeBinding: Codable {
    let account_id: String
    let folder_id: String
    let expected_name: String
    func validate() throws {
        try canonicalID(account_id, entity: "ICAccount")
        try canonicalID(folder_id, entity: "ICFolder")
        guard !expected_name.isEmpty, expected_name.utf8.count <= 1024 else { throw NativeFault("invalid_arguments") }
    }
    var account: NSAppleEventDescriptor { get throws { try NotesEvents.object(NotesEvents.account, id: account_id) } }
    var folder: NSAppleEventDescriptor { get throws { try NotesEvents.object(NotesEvents.folder, id: folder_id, in: account) } }
    func note(_ id: String) throws -> NSAppleEventDescriptor {
        try canonicalID(id, entity: "ICNote")
        return try NotesEvents.object(NotesEvents.note, id: id, in: folder)
    }
}

func canonicalID(_ id: String, entity: String) throws {
    let pattern = "^x-coredata://[0-9a-fA-F-]+/" + entity + "/p[1-9][0-9]*$"
    guard id.range(of: pattern, options: .regularExpression) == id.startIndex..<id.endIndex else { throw NativeFault("invalid_arguments") }
}

final class NativeNotes {
    let binding: NativeBinding
    let deadline: Double
    let grantExpiresAtMS: Int64
    private(set) var effectStarted = false
    init(binding: NativeBinding, timeout: Double = 20, grantExpiresAtMS: Int64? = nil) throws {
        try binding.validate()
        self.binding = binding
        let now = Date().timeIntervalSince1970
        self.grantExpiresAtMS = grantExpiresAtMS ?? Int64((now + timeout) * 1000)
        let remaining = Double(self.grantExpiresAtMS) / 1000 - now
        guard remaining > 0 else { throw NativeFault("grant_expired") }
        deadline = ProcessInfo.processInfo.systemUptime + min(timeout, remaining)
    }
    func ready(_ eventIDs: [UInt32]) throws {
        // Screen lock is not an authorization boundary for already-approved
        // background Apple Events. Never require UI or unlock the screen.
        // Password-protected NOTES are still refused in snapshotOnce.
        try budget()
        let target = NSAppleEventDescriptor(applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))
        for event in eventIDs {
            // askUserIfNeeded is ALWAYS false. No new/persistent consent.
            switch AEDeterminePermissionToAutomateTarget(target.aeDesc, NotesEvents.core, event, false) {
            case noErr: continue
            case -1743, -1744: throw NativeFault("needs_permission")
            default: throw NativeFault("permission_unknown")
            }
        }
    }
    func budget() throws {
        guard Int64(Date().timeIntervalSince1970 * 1000) < grantExpiresAtMS else { throw NativeFault("grant_expired") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFault("deadline_exceeded") }
    }
    func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try budget()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw NativeFault("deadline_exceeded") }
        let options = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent))
        do {
            let reply = try event.sendEvent(options: options, timeout: min(5, remaining))
            if let error = reply.paramDescriptor(forKeyword: 0x6572726e), error.int32Value != 0 {
                switch error.int32Value {
                case -1743, -1744: throw NativeFault("needs_permission")
                case -1728: throw NativeFault("not_found")
                case -1712: throw NativeFault("unavailable")
                default: throw NativeFault("automation_failed")
                }
            }
            // save may return no direct parameter, which is valid only when
            // the export caller verifies the actual resulting file.
            return reply.paramDescriptor(forKeyword: NotesEvents.direct) ?? .null()
        } catch let error as NativeFault { throw error }
        catch let error as NSError {
            switch error.code {
            case -1743, -1744: throw NativeFault("needs_permission")
            case -1712: throw NativeFault("unavailable")
            case -1728: throw NativeFault("not_found")
            default: throw NativeFault("automation_failed")
            }
        }
    }
    func text(_ code: UInt32, of object: NSAppleEventDescriptor, limit: Int = 2 * 1024 * 1024) throws -> String {
        let value = try send(NotesEvents.read(code, of: object))
        guard let string = value.stringValue, string.utf8.count <= limit else { throw NativeFault("invalid_or_oversized_native_response") }
        return string
    }
    func bool(_ code: UInt32, of object: NSAppleEventDescriptor) throws -> Bool {
        let value = try send(NotesEvents.read(code, of: object))
        guard value.descriptorType == typeBoolean else { throw NativeFault("invalid_native_response") }
        return value.booleanValue
    }
    func optionalText(_ code: UInt32, of object: NSAppleEventDescriptor) throws -> String {
        let value = try send(NotesEvents.read(code, of: object))
        if value.descriptorType == typeNull || value.descriptorType == 0x6d736e67 { return "" }
        guard let string = value.stringValue, string.utf8.count <= 8192 else { throw NativeFault("invalid_native_response") }
        return string
    }
    func modified(_ object: NSAppleEventDescriptor) throws -> String {
        let value = try send(NotesEvents.read(NotesEvents.modified, of: object))
        guard let date = value.dateValue else { throw NativeFault("invalid_native_response") }
        return String(format: "%.6f", date.timeIntervalSince1970)
    }
    func count(_ kind: UInt32, in parent: NSAppleEventDescriptor) throws -> Int {
        let event = NotesEvents.event(NotesEvents.count)
        event.setParam(try NotesEvents.all(kind, in: parent), forKeyword: NotesEvents.direct)
        let value = try send(event)
        guard value.descriptorType == typeSInt32, value.int32Value >= 0 else { throw NativeFault("invalid_native_response") }
        return Int(value.int32Value)
    }
    func folderMetadata() throws -> [String: Any] {
        let folder = try binding.folder
        let actualAccount = try text(NotesEvents.id, of: binding.account, limit: 1024)
        let actualFolder = try text(NotesEvents.id, of: folder, limit: 1024)
        let parent = try NotesEvents.property(NotesEvents.container, of: folder)
        let parentID = try text(NotesEvents.id, of: parent, limit: 1024)
        let name = try text(NotesEvents.name, of: folder, limit: 1024)
        let shared = try bool(NotesEvents.shared, of: folder)
        guard actualAccount == binding.account_id, actualFolder == binding.folder_id,
              parentID == binding.account_id, name == binding.expected_name, !shared else { throw NativeFault("target_changed") }
        return ["account_id": actualAccount, "folder_id": actualFolder, "expected_name": name, "shared": shared, "top_level": true]
    }
    func noteRef(_ id: String) throws -> NSAppleEventDescriptor {
        try canonicalID(id, entity: "ICNote")
        // Every later property/save/make event retains this account/folder
        // container. Never follow a globally addressed note after a move.
        let note = try binding.note(id)
        let actualID = try text(NotesEvents.id, of: note, limit: 1024)
        let parent = try NotesEvents.property(NotesEvents.container, of: note)
        let parentID = try text(NotesEvents.id, of: parent, limit: 1024)
        guard actualID == id, parentID == binding.folder_id else { throw NativeFault("target_changed") }
        return note
    }
    func attachmentMetadata(_ note: NSAppleEventDescriptor) throws -> [[String: String]] {
        let total = try count(NotesEvents.attachment, in: note)
        guard total <= 1000 else { throw NativeFault("too_many_attachments") }
        var result: [[String: String]] = []
        if total > 0 {
            for index in 1...total {
                let object = try NotesEvents.indexed(NotesEvents.attachment, index: index, in: note)
                let id = try text(NotesEvents.id, of: object, limit: 1024)
                try canonicalID(id, entity: "ICAttachment")
                // Some non-file object properties may be missing. Keep them
                // explicit rather than inventing file paths or fetching URLs.
                let name = try optionalText(NotesEvents.name, of: object)
                let cid = try optionalText(0x63696420, of: object)
                let url = try optionalText(0x55524c20, of: object)
                result.append(["id": id, "name": name, "content_identifier": cid, "url": url, "modified": try modified(object)])
            }
        }
        return result.sorted { $0["id"]! < $1["id"]! }
    }
    func snapshotOnce(_ id: String) throws -> [String: Any] {
        let note = try noteRef(id)
        guard try !bool(NotesEvents.password, of: note) else { throw NativeFault("needs_unlock") }
        let initialModified = try modified(note)
        let result: [String: Any] = ["id": id, "account_id": binding.account_id, "folder_id": binding.folder_id,
                                   "title": try text(NotesEvents.name, of: note, limit: 4096),
                                   "html": try text(NotesEvents.body, of: note), "plaintext": try text(NotesEvents.plaintext, of: note),
                                   "modified": initialModified, "password_protected": false, "shared": try bool(NotesEvents.shared, of: note),
                                   "attachments": try attachmentMetadata(note)]
        guard try modified(note) == initialModified else { throw NativeFault("revision_conflict") }
        return result
    }
    func snapshot(_ id: String) throws -> [String: Any] {
        let first = try snapshotOnce(id), second = try snapshotOnce(id)
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: first, options: options) == JSONSerialization.data(withJSONObject: second, options: options) else {
            throw NativeFault("revision_conflict")
        }
        return second
    }
    func search(query: String, body: Bool, limit: Int, scan: Int) throws -> [String: Any] {
        let folder = try binding.folder
        let total = try count(NotesEvents.note, in: folder)
        var notes: [[String: Any]] = [], unreadable = 0, scanned = 0
        let maximum = min(total, scan)
        if maximum > 0 {
            for index in 1...maximum {
                scanned += 1
                let object = try NotesEvents.indexed(NotesEvents.note, index: index, in: folder)
                do {
                    let title = try text(NotesEvents.name, of: object, limit: 4096)
                    let protected = try bool(NotesEvents.password, of: object)
                    var matched = title.localizedCaseInsensitiveContains(query)
                    if body && !matched {
                        if protected { unreadable += 1; continue }
                        matched = try text(NotesEvents.plaintext, of: object).localizedCaseInsensitiveContains(query)
                    }
                    if matched {
                        let id = try text(NotesEvents.id, of: object, limit: 1024)
                        _ = try noteRef(id)
                        notes.append(["id": id, "title": title, "account_id": binding.account_id, "folder_id": binding.folder_id,
                                      "modified": try modified(object), "password_protected": protected, "shared": try bool(NotesEvents.shared, of: object)])
                        if notes.count >= limit { break }
                    }
                } catch let error as NativeFault {
                    // Only per-note read failures make coverage partial;
                    // authority/deadline/target errors stop the entire request.
                    guard ["not_found", "invalid_or_oversized_native_response", "needs_unlock"].contains(error.code) else { throw error }
                    unreadable += 1
                }
            }
        }
        return ["notes": notes, "scanned": scanned, "scan_truncated": scanned < total, "unreadable": unreadable]
    }
    func candidates(title: String, scope: String) throws -> [String] {
        // Global indexed selection cannot bind an append effect to the granted
        // scripting ID. Do not enumerate personal collision metadata either.
        throw NativeFault("unsupported_operation")
    }
    func create(title: String, html: String, finalAdmission: () throws -> Void = {}) throws -> [String: String] {
        _ = try folderMetadata()
        try ready([NotesEvents.make])
        let event = try NotesEvents.create(title: title, html: html, at: binding.folder)
        // The responsible host can revoke a peer/epoch/grant while metadata
        // or readiness work runs. Check it after those callbacks, directly
        // before synchronous send; descriptor construction itself is pure.
        try finalAdmission()
        effectStarted = true
        let reference = try send(event)
        guard reference.descriptorType == 0x6f626a20 else { throw NativeFault("invalid_native_response") }
        let id = try text(NotesEvents.id, of: reference, limit: 1024)
        try canonicalID(id, entity: "ICNote")
        return ["id": id]
    }
    func privateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arl-notes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    func attachmentRef(noteID: String, attachmentID: String) throws -> NSAppleEventDescriptor {
        try canonicalID(attachmentID, entity: "ICAttachment")
        let note = try noteRef(noteID)
        let reference = try NotesEvents.object(NotesEvents.attachment, id: attachmentID, in: note)
        guard try text(NotesEvents.id, of: reference, limit: 1024) == attachmentID else { throw NativeFault("not_found") }
        let parent = try NotesEvents.property(NotesEvents.container, of: reference)
        guard try text(NotesEvents.id, of: parent, limit: 1024) == noteID else { throw NativeFault("target_changed") }
        return reference
    }
    func fetch(noteID: String, attachmentID: String) throws -> [String: String] {
        let reference = try attachmentRef(noteID: noteID, attachmentID: attachmentID)
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("attachment")
        _ = try send(NotesEvents.export(reference, to: file))
        let info = try FileManager.default.attributesOfItem(atPath: file.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              let size = info[.size] as? NSNumber, size.intValue > 0, size.intValue <= 8 * 1024 * 1024 else { throw NativeFault("unsupported_or_oversized_attachment") }
        let data = try Data(contentsOf: file)
        guard data.count == size.intValue else { throw NativeFault("revision_conflict") }
        return ["id": noteID, "attachment_id": attachmentID, "data_base64": data.base64EncodedString()]
    }
    func revision(_ snapshot: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .withoutEscapingSlashes])
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func attach(noteID: String, filename: String, data: Data, expectedRevision: String) throws -> [String: String] {
        // Scoped descriptors are expressible and fixture-checked; actual
        // Notes scoped resolution/export acceptance has not run. No boolean
        // acceptance flag can re-enable this write in this version.
        throw NativeFault("unsupported_operation")
    }
}
