import Foundation
import SQLite3
import Security
import Darwin

@MainActor @main enum MessagesReceiveRelayTests {
    static func signingRequirement() throws -> String {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw MessagesReceiveFault("fixture_signature_unavailable") }
        return "cdhash H\"" + hash.map { String(format:"%02x",$0) }.joined() + "\""
    }
    static func insertNew(_ database: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path,&db) == SQLITE_OK,let db else { throw MessagesReceiveFault("fixture_open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db,"INSERT INTO message(ROWID,guid,text,handle_id,is_from_me,date,service,associated_message_type,item_type) VALUES(2,'synthetic-new','ARL-TEST signed cross-process receive',1,0,2,'iMessage',0,0);INSERT INTO chat_message_join VALUES(1,2);",nil,nil,nil) == SQLITE_OK else { throw MessagesReceiveFault("fixture_write") }
    }
    static func main() async throws {
        let mode=CommandLine.arguments[1],home=URL(fileURLWithPath:CommandLine.arguments[2])
        if mode != "--delivery" {
            let server: MessagesReceiveRelayServer
            do {
                server=try MessagesReceiveRelayServer.start(home:home,authorize:{_ in throw MessagesReceiveFault("fixture_no_peer")},call:{_,_ in throw MessagesReceiveFault("fixture_no_call")})
            } catch let error as MessagesReceiveFault {
                if mode == "--expect-busy" && error.code == "receive_relay_owner_busy" {print("PASS live owner held");return}
                if mode == "--expect-held" && error.code == "receive_relay_socket_cleanup_required" {print("PASS live foreign listener held");return}
                throw error
            }
            if mode == "--recover" {
                guard await server.stopAndDrain() else {throw MessagesReceiveFault("fixture_not_drained")}
                print("PASS stale socket recovered and drained");return
            }
            try Data("ready".utf8).write(to:home.appendingPathComponent("ready"),options:.atomic)
            try await Task.sleep(for:.seconds(240));_ = await server.stopAndDrain();return
        }
        let python=URL(fileURLWithPath:CommandLine.arguments[3]),script=CommandLine.arguments[4],helper=CommandLine.arguments[5]
        let owner=try MessagesReceiveService(home:home,databaseURL:home.appendingPathComponent("chat.db"))
        let selection=try owner.selections().entries[0]
        _ = try owner.enable(selection:selection,consumerAppID:"synthetic.agent")
        try insertNew(home.appendingPathComponent("chat.db"))
        let child=Process();child.executableURL=python
        child.arguments=["-B",script,"--core",home.path,try signingRequirement(),helper]
        let output=Pipe(),errors=Pipe();child.standardOutput=output;child.standardError=errors
        let server=try MessagesReceiveRelayServer.start(home:home,authorize:{fd in
            try await MainActor.run {
                guard child.isRunning else {throw MessagesReceiveFault("fixture_core_not_running")}
                return try MessagesReceiveRelayPeer(fd:fd,expectedPID:child.processIdentifier,expectedExecutable:python,expectedParentPID:getpid())
            }
        },call:{request,peer in
            let args=try JSONSerialization.jsonObject(with:request.parameters) as! [String:Any]
            return try owner.dispatch(method:request.method,parameters:args,consumer:request.consumer,verify:{_ in try peer.verify()})
        })
        try child.run()
        let deadline=ProcessInfo.processInfo.systemUptime+45
        while child.isRunning && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(for:.milliseconds(20))}
        if child.isRunning {child.terminate()}
        child.waitUntilExit()
        let stdout=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self),stderr=String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        guard await server.stopAndDrain() else {throw MessagesReceiveFault("fixture_not_drained")}
        guard child.terminationStatus==0 else {FileHandle.standardError.write(Data((stdout+"\n"+stderr).utf8));throw MessagesReceiveFault("fixture_core_failed")}
        guard stdout.contains("signed native delivery"),owner.status().pendingCount==0 else {throw MessagesReceiveFault("fixture_delivery_failed")}
        print("PASS native -> registered/signed core -> registered/signed app -> native SQLite, pull/ack; real Messages=0")
    }
}
