import Foundation

@main enum CodexScopePolicyTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw Failure.assertion(name) }
    }
    @MainActor static func main() throws {
        let manifest=String(repeating:"a",count:64), requirement="synthetic-owner-requirement"
        let fresh=try CodexScopeOwner.configuration(previous:nil,manifest:manifest,requirement:requirement)
        let first=try OwnerReadJSON.object(fresh,limit:4096)
        try expect(NASCapability.integer(first["schema_version"])==2 && first["max_calls"] is NSNull,"new native scope has no local lifetime call quota")
        let again=try CodexScopeOwner.configuration(previous:fresh,manifest:manifest,requirement:requirement)
        try expect(fresh==again,"unchanged configuration retains scope generation")
        var legacy=first;legacy["schema_version"]=1;legacy["max_calls"]=32
        let old=try OwnerReadWire.encode(legacy,limit:4096)
        let kept=try OwnerReadJSON.object(CodexScopeOwner.configuration(previous:old,manifest:manifest,requirement:requirement),limit:4096)
        try expect(NASCapability.integer(kept["schema_version"])==1 && NASCapability.integer(kept["max_calls"])==32,"existing finite authorization is preserved")
        let upgraded=try OwnerReadJSON.object(CodexScopeOwner.configuration(previous:old,manifest:String(repeating:"b",count:64),requirement:requirement),limit:4096)
        try expect(upgraded["scope_generation"] as? String != kept["scope_generation"] as? String && NASCapability.integer(upgraded["max_calls"])==32,"code update renews identity binding without widening finite policy")
        legacy["max_calls"]=NSNull()
        do {
            _ = try CodexScopeOwner.configuration(previous:OwnerReadWire.encode(legacy,limit:4096),manifest:manifest,requirement:requirement)
            throw Failure.assertion("schema 1 null quota admitted")
        } catch let error as ARLError { try expect(error.code=="codex_scope_review_required","legacy malformed policy rejects") }
        print("PASS native Codex quota defaults, stable scope and preservation across identity update; no model or installed state access")
    }
}
