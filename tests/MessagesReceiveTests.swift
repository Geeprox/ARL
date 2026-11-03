import Foundation
import SQLite3
import Darwin

@MainActor @main enum MessagesReceiveTests {
    static var checks = 0
    struct Failure: Error { let name: String }
    struct Pull: Decodable { let status: MessagesReceiveStatus; let batch: MessagesReceiveBatch? }
    static let consumer = MessagesReceiveConsumer(appID: "synthetic.agent", sessionID: "verified-session", registrationGeneration: "verified-generation", authorizedCapabilities: [MessagesReceiveService.capability])
    static func expect(_ value: Bool, _ name: String) throws { guard value else { throw Failure(name: name) }; checks += 1 }
    static func reject(_ code: String? = nil, _ body: () throws -> Void) throws {
        do { try body() } catch let fault as MessagesReceiveFault {
            if let code { try expect(fault.code == code, "expected \(code), got \(fault.code)") } else { checks += 1 }; return
        }
        throw Failure(name: "expected rejection " + (code ?? ""))
    }
    static func execute(_ database: URL, _ sql: String) throws {
        var value: OpaquePointer?
        guard sqlite3_open(database.path, &value) == SQLITE_OK, let value else { throw Failure(name: "synthetic SQLite open") }
        defer { sqlite3_close(value) }
        guard sqlite3_exec(value, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(name: "synthetic SQLite statement") }
    }
    static func insert(_ database: URL, id: Int, chat: Int = 1, text: String = "Synthetic new text", outgoing: Bool = false, attributed: Bool = false, kind: Int = 0) throws {
        let escaped = text.replacingOccurrences(of: "'", with: "''")
        try execute(database, "INSERT INTO message(ROWID,guid,text,attributedBody,handle_id,is_from_me,date,service,associated_message_type,item_type) VALUES(\(id),'synthetic-message-\(id)','\(escaped)',\(attributed ? "X'0102'" : "NULL"),1,\(outgoing ? 1 : 0),\(id),'iMessage',\(kind),0);INSERT INTO chat_message_join(chat_id,message_id) VALUES(\(chat),\(id));")
    }
    static func make(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("source/chat.db")
        try execute(database, "CREATE TABLE chat(guid TEXT,account_login TEXT,display_name TEXT,service_name TEXT);CREATE TABLE handle(id TEXT,service TEXT);CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);CREATE TABLE message(guid TEXT,text TEXT,attributedBody BLOB,handle_id INTEGER,is_from_me INTEGER,date INTEGER,service TEXT,associated_message_type INTEGER,item_type INTEGER);INSERT INTO chat VALUES('iMessage;-;synthetic-peer','synthetic-account@example.test','Synthetic peer','iMessage');INSERT INTO chat VALUES('iMessage;-;other-peer','other-account@example.test','Other scope','iMessage');INSERT INTO handle VALUES('peer@example.test','iMessage');INSERT INTO chat_handle_join VALUES(1,1);INSERT INTO chat_handle_join VALUES(2,1);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        try insert(database, id: 1, text: "OLD HISTORY MUST NEVER APPEAR")
        try insert(database, id: 2, chat: 2, text: "OTHER CHAT MUST NEVER APPEAR")
        try insert(database, id: 3, outgoing: true)
    }
    static func service(_ root: URL) throws -> MessagesReceiveService { try .init(home: root.appendingPathComponent("state"), databaseURL: root.appendingPathComponent("source/chat.db")) }
    static func pull(_ owner: MessagesReceiveService, scope: UUID) throws -> Pull {
        try JSONDecoder().decode(Pull.self, from: owner.dispatch(method: "messages.receive.pull", parameters: ["scope_id": scope.uuidString.lowercased()], consumer: consumer, verify: { binding in
            guard binding.sessionID == consumer.sessionID && binding.registrationGeneration == consumer.registrationGeneration else { throw MessagesReceiveFault("test_unverified_binding") }
        }))
    }
    static func ack(_ owner: MessagesReceiveService, _ batch: MessagesReceiveBatch) throws {
        _ = try owner.dispatch(method: "messages.receive.ack", parameters: ["scope_id": batch.scopeID.uuidString.lowercased(), "batch_id": batch.id.uuidString.lowercased(), "batch_digest": batch.digest], consumer: consumer, verify: { _ in })
    }
    static func child(_ mode: String, root: URL) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [mode, root.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != (mode == "--crash" ? 23 : 0) { throw Failure(name: "child \(mode): \(text)") }
        return process.terminationStatus
    }
    static func firstPhase(_ root: URL) throws -> MessagesReceiveBatch {
        let owner = try service(root), database = root.appendingPathComponent("source/chat.db")
        try expect(!owner.status().enabled && !owner.status().running, "default disabled")
        let selections = try owner.selections().entries
        let selection = selections.first { $0.conversation.rowID == 1 }!
        let status = try owner.enable(selection: selection, consumerAppID: consumer.appID)
        try expect(status.cursor == 3 && status.scope?.startRowID == 3, "baseline captures current global high water without history")
        _ = try child("--busy", root: root)
        try insert(database, id: 4, text: "Synthetic fresh incoming")
        try insert(database, id: 5, chat: 2, text: "OUTSIDE SCOPE BODY")
        try insert(database, id: 6, outgoing: true)
        try insert(database, id: 7, text: "", attributed: true)
        try insert(database, id: 8, text: "Reaction payload", kind: 2000)
        let batch = try pull(owner, scope: status.scope!.id).batch!
        try expect(batch.events.map(\.rowID) == [4,7,8], "only selected new incoming rows")
        try expect(batch.events[0].text == "Synthetic fresh incoming", "exact plain text")
        try expect(batch.events[1].text == "" && batch.events[1].coverage == "unsupported_attributed_body", "attributed body is never guessed")
        try expect(batch.events[2].text == nil && batch.events[2].coverage == "unsupported_message_kind", "reaction is explicit unsupported, not new text")
        try expect(try pull(owner, scope: status.scope!.id).batch?.digest == batch.digest, "lost response returns the same frozen batch")
        try reject("receive_ack_mismatch") {
            _ = try owner.dispatch(method: "messages.receive.ack", parameters: ["scope_id": batch.scopeID.uuidString.lowercased(), "batch_id": batch.id.uuidString.lowercased(), "batch_digest": String(repeating:"0",count:64)], consumer: consumer, verify: { _ in })
        }
        let wrongApp = MessagesReceiveConsumer(appID: "other.agent", sessionID: "s", registrationGeneration: "g", authorizedCapabilities: [MessagesReceiveService.capability])
        try reject("receive_consumer_not_authorized") { _ = try owner.dispatch(method: "messages.receive.pull", parameters: ["scope_id":batch.scopeID.uuidString.lowercased()], consumer: wrongApp, verify: { _ in }) }
        let noGrant = MessagesReceiveConsumer(appID: consumer.appID, sessionID: "s", registrationGeneration: "g", authorizedCapabilities: [])
        try reject("receive_consumer_not_authorized") { _ = try owner.dispatch(method: "messages.receive.pull", parameters: ["scope_id":batch.scopeID.uuidString.lowercased()], consumer: noGrant, verify: { _ in }) }
        try reject("test_revoked_binding") { _ = try owner.dispatch(method: "messages.receive.pull", parameters: ["scope_id":batch.scopeID.uuidString.lowercased()], consumer: consumer, verify: { _ in throw MessagesReceiveFault("test_revoked_binding") }) }
        try reject("invalid_receive_request") { _ = try owner.dispatch(method: "messages.receive.pull", parameters: ["scope_id":batch.scopeID.uuidString.lowercased(),"database_path":"/tmp/forbidden"], consumer: consumer, verify: { _ in }) }
        let raw = try String(contentsOf: root.appendingPathComponent("state/messages-receive-v1/state.json"), encoding:.utf8)
        try expect(!raw.contains("OLD HISTORY") && !raw.contains("OUTSIDE SCOPE BODY") && !raw.contains("OTHER CHAT"), "old/other bodies never enter persistent delivery")
        try expect(raw.contains("volumeUUID") && !raw.contains("\"device\""), "persistent identity uses volume UUID, not transient st_dev")
        return batch
    }
    static func secondPhase(_ root: URL) throws {
        let owner = try service(root), database = root.appendingPathComponent("source/chat.db")
        try expect(owner.status().pendingCount == 0 && !owner.status().running, "cross-process ack persists, startup never captures")
        _ = try owner.resumeFromNow()
        try insert(database, id: 10)
        let batch = try pull(owner, scope: owner.status().scope!.id).batch!
        try expect(batch.events.map(\.rowID) == [10], "paused row 9 is not backfilled")
        try owner.revoke()
        try reject("receive_consumer_not_authorized") { _ = try pull(owner, scope: batch.scopeID) }
        try expect(owner.status().pendingCount == 1, "revoke suppresses delivery without deleting unknown batch")
        try owner.discardPendingAfterReview()
        let selection = try owner.selections().entries.first { $0.conversation.rowID == 1 }!
        _ = try owner.enable(selection: selection, consumerAppID: consumer.appID)
    }
    static func afterCrash(_ root: URL) throws {
        let owner = try service(root), database = root.appendingPathComponent("source/chat.db")
        try expect(owner.status().pendingCount == 1 && !owner.status().running, "SIGKILL-equivalent exit preserves pending and default pause")
        let scope = owner.status().scope!.id
        try reject("receive_paused_or_revoked") { _ = try pull(owner, scope: scope) }
        _ = try owner.resumeFromNow()
        let recovered = try pull(owner, scope: scope).batch!
        try expect(recovered.events.map(\.rowID) == [11], "crash persisted the exact new incoming row")
        try ack(owner,recovered)
        try insert(database,id:12)
        let pending = try pull(owner,scope:scope).batch!
        try ack(owner,recovered)
        try expect(owner.status().pendingCount==1 && (try pull(owner,scope:scope).batch?.digest)==pending.digest,"repeated previous ack never deletes the next pending batch")
        try execute(database,"INSERT INTO handle VALUES('changed-peer@example.test','iMessage');INSERT INTO chat_handle_join VALUES(1,2);")
        try reject("messages_receive_scope_changed") { _ = try pull(owner,scope:scope) }
        try expect(!owner.status().running && owner.status().pendingCount == 1,"changed membership pauses even with a pending batch")
        try execute(database,"DELETE FROM chat_handle_join WHERE chat_id=1 AND handle_id=2;")
        _ = try owner.resumeFromNow();try ack(owner,pending)
        let original = root.appendingPathComponent("source/original.db")
        try FileManager.default.moveItem(at:database,to:original)
        try FileManager.default.copyItem(at:original,to:database)
        try reject("messages_database_changed") { _ = try owner.capture() }
        try expect(!owner.status().running,"source replacement cannot keep capture running")
    }
    static func paginationAndReadOnlyGuards(_ root: URL) throws {
        let database = root.appendingPathComponent("source/chat.db")
        try execute(database,"WITH RECURSIVE ids(x) AS (VALUES(3) UNION ALL SELECT x+1 FROM ids WHERE x<205) INSERT INTO chat(ROWID,guid,account_login,display_name,service_name) SELECT x,'synthetic-chat-'||x,'synthetic-account@example.test','Synthetic','iMessage' FROM ids;WITH RECURSIVE ids(x) AS (VALUES(3) UNION ALL SELECT x+1 FROM ids WHERE x<205) INSERT INTO chat_handle_join(chat_id,handle_id) SELECT x,1 FROM ids;")
        do {
            let owner = try service(root)
            let first = try owner.selections()
            let second = try owner.selections(beforeRowID:first.nextBeforeRowID!)
            try expect(first.entries.count == 200 && second.entries.count == 5 && second.nextBeforeRowID == nil,"metadata pages beyond 200 conversations")
            try expect(Set(first.entries.map(\.conversation.rowID)).isDisjoint(with:second.entries.map(\.conversation.rowID)),"metadata continuation has no duplicate rows")
            try owner.revoke()
        }
        let wal = URL(fileURLWithPath:database.path+"-wal")
        try FileManager.default.createSymbolicLink(at:wal,withDestinationURL:database)
        try reject("unsafe_messages_sidecar") { _ = try MessagesReceiveDatabase(url:database) }
        try FileManager.default.removeItem(at:wal)
        let stateRoot = root.appendingPathComponent("state")
        let anchor = stateRoot.appendingPathComponent("messages-receive-v1.anchor")
        let kept = stateRoot.appendingPathComponent("preserved.anchor")
        try FileManager.default.moveItem(at:anchor,to:kept)
        try FileManager.default.createSymbolicLink(at:anchor,withDestinationURL:kept)
        try reject("receive_state_unsafe") { _ = try service(root) }
        try FileManager.default.removeItem(at:anchor)
        try FileManager.default.moveItem(at:kept,to:anchor)
        let fresh = root.appendingPathComponent("empty-state")
        try FileManager.default.createDirectory(at:fresh,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let unopened = try MessagesReceiveService(home:fresh,databaseURL:root.appendingPathComponent("does-not-exist.db"))
        try expect(!unopened.status().enabled,"construction/status do not open a missing protected source")
    }
    static func wireBudgets(_ root: URL) throws {
        let database=root.appendingPathComponent("source/chat.db"),home=root.appendingPathComponent("budget-state")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for id in 3...17 {try execute(database,"INSERT INTO handle(ROWID,id,service) VALUES(\(id),'peer-\(id)@example.test','iMessage');INSERT INTO chat_handle_join VALUES(1,\(id));")}
        let title=String(repeating:"中\"\\",count:500).replacingOccurrences(of:"'",with:"''")
        try execute(database,"UPDATE chat SET display_name='\(title)' WHERE ROWID=1;")
        let owner=try MessagesReceiveService(home:home,databaseURL:database)
        let selection=try owner.selections(beforeRowID:2).entries[0]
        try expect(selection.conversation.participants.count==16,"maximum supported members retained")
        let status=try owner.enable(selection:selection,consumerAppID:consumer.appID),scope=status.scope!.id
        let body=String(repeating:"测\"\\\\\n",count:3000)
        for id in 20...22 {try insert(database,id:id,text:body)}
        var received:[Int64]=[]
        while true {
            let data=try owner.dispatch(method:"messages.receive.pull",parameters:["scope_id":scope.uuidString.lowercased()],consumer:consumer,verify:{_ in})
            let object=try JSONSerialization.jsonObject(with:data)
            let core=try JSONSerialization.data(withJSONObject:["protocol":"arl/1","ok":true,"result":object],options:[.sortedKeys,.withoutEscapingSlashes])
            try expect(data.count<=96*1024 && core.count<131072,"actual Unicode/quote/backslash core response remains within 128KiB")
            let reply=try JSONDecoder().decode(Pull.self,from:data)
            guard let batch=reply.batch else {break}
            try expect(batch.events.allSatisfy{$0.text==body && $0.coverage=="plain_text_only"},"no silent body trimming at batch boundary")
            received+=batch.events.map(\.rowID);try ack(owner,batch)
        }
        try expect(received==[20,21,22],"encoded byte continuation retains every new row")
        try insert(database,id:23,text:String(repeating:"\u{1}",count:60000))
        let oversized=try pull(owner,scope:scope).batch!
        try expect(oversized.events.count==1 && oversized.events[0].text==nil && oversized.events[0].coverage=="body_exceeds_receive_budget","oversize escaped body is explicit unsupported, not absent")
        try ack(owner,oversized)
    }
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { throw Failure(name:"owned fixture root required") }
        let isChild = CommandLine.arguments[1].hasPrefix("--")
        let root = URL(fileURLWithPath:CommandLine.arguments[isChild ? 2:1])
        guard root.path.hasPrefix("/"), root.path.split(separator:"/").allSatisfy({$0 != "." && $0 != ".."}) else { throw Failure(name:"absolute owned fixture root required") }
        if isChild {
            let mode = CommandLine.arguments[1]
            if mode == "--busy" { try reject("receive_owner_busy") { _ = try service(root) };return }
            let owner = try service(root)
            if mode == "--crash" { _ = try owner.resumeFromNow();try insert(root.appendingPathComponent("source/chat.db"),id:11);_ = try owner.capture();_exit(23) }
            try expect(owner.status().pendingCount == 3 && !owner.status().running,"fresh process sees durable pending only")
            _ = try owner.resumeFromNow();let batch = try pull(owner,scope:owner.status().scope!.id).batch!
            try expect(batch.events.map(\.rowID) == [4,7,8],"reopen does not replace pending batch with newer rows")
            try ack(owner,batch);try ack(owner,batch);return
        }
        try make(root)
        _ = try firstPhase(root)
        try insert(root.appendingPathComponent("source/chat.db"),id:9,text:"Arrived while stopped")
        _ = try child("--pull",root:root)
        try secondPhase(root)
        _ = try child("--crash",root:root)
        try afterCrash(root)
        try paginationAndReadOnlyGuards(root)
        try wireBudgets(root)
        let link = root.appendingPathComponent("source/link.db")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root.appendingPathComponent("source/chat.db"))
        try reject("unsafe_messages_database") { _ = try MessagesReceiveDatabase(url:link) }
        print("PASS \(checks) native receive checks plus three real child processes; real Messages reads=0 sends=0")
    }
}
