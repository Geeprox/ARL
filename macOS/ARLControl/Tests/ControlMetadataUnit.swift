import Foundation

@main struct ControlMetadataUnit {
    static func main() async throws {
        var cases: [[String:Any]] = []
        func check(_ name:String,_ passed:Bool) { cases.append(["name":name,"passed":passed]) }
        let snapshot=try ControlPlaneSnapshot.decode(Data(ControlFixtures.snapshot.utf8))
        check("explicit-v2-fixture",snapshot.schema_version==2 && snapshot.apps.allSatisfy {$0.connection != "connected"})
        check("catalog-never-loaded",snapshot.providers[0].state == "discovered" && snapshot.providers[0].model_load_state == "unknown" && !snapshot.providers[0].inference_enabled)
        check("first-process-cpu-null",snapshot.resources.processes[0].cpu_percent == nil)
        check("apple-action-unapproved",snapshot.apple_apps.flatMap(\.actions).allSatisfy {!$0.authorized && $0.permission=="not_checked"})
        let original = try JSONSerialization.jsonObject(with:Data(ControlFixtures.snapshot.utf8))
        func changed(_ value:Any,_ path:[String],_ replacement:Any) -> Any {
            if path.isEmpty { return replacement }
            if var object=value as? [String:Any] { object[path[0]]=changed(object[path[0]]!,Array(path.dropFirst()),replacement);return object }
            var array=value as! [Any];let i=Int(path[0])!;array[i]=changed(array[i],Array(path.dropFirst()),replacement);return array
        }
        let negatives: [(String,[String],Any)] = [
            ("schema-version",["schema_version"],3),("protocol",["protocol"],"other"),
            ("boolean-as-integer",["checked_at_ms"],true),("number-as-boolean",["runtime","ui_required"],0),
            ("unknown-runtime",["runtime","state"],"green"),("ui-required",["runtime","ui_required"],true),
            ("app-id-foreign-path",["apps","0","id"],"/private/key"),("invalid-icon",["apps","0","icon_ref"],"file:/private/icon"),
            ("long-name",["apps","0","name"],String(repeating:"名",count:201)),
            ("long-version",["apps","0","version"],String(repeating:"v",count:81)),
            ("connected-without-evidence",["apps","0","connection"],"connected"),
            ("provider-invented-loaded",["providers","0","model_load_state"],"loaded"),
            ("provider-unknown-evidence",["providers","0","evidence"],"process_seen"),
            ("system-cpu-over-100",["resources","system_cpu_percent"],101),
            ("negative-rss",["resources","processes","0","rss_bytes"],-1),
            ("cpu-boolean",["resources","processes","0","cpu_percent"],false),
            ("invalid-pressure",["resources","memory_pressure"],"inferred_free_ram"),
            ("too-fast-sample",["resources","minimum_interval_ms"],1000),
            ("gpu-claim",["resources","gpu_allocation"],"measured"),
            ("process-count",["resources","processes"],Array(repeating:(snapshot.resources.processes.map { try! JSONSerialization.jsonObject(with:JSONEncoder().encode($0)) })[0],count:33)),
            ("credential-provider-revoke",["credentials","0","provider_revocation"],"revoked"),
            ("apple-unknown-permission",["apple_apps","0","actions","0","permission"],"app_connected"),
            ("household-other-owner",["household","owner_app"],"settings"),
            ("capability-long-id",["household","read_capabilities"],[String(repeating:"a",count:81)])
        ]
        for (name,path,value) in negatives {
            do { _=try ControlPlaneSnapshot.decode(JSONSerialization.data(withJSONObject:changed(original,path,value)));check("reject-"+name,false) }
            catch { check("reject-"+name,true) }
        }
        var extra=original as! [String:Any];extra["endpoint"]="synthetic"
        do { _=try ControlPlaneSnapshot.decode(JSONSerialization.data(withJSONObject:extra));check("reject-unlisted-field",false) } catch { check("reject-unlisted-field",true) }
        let high=try ControlPlaneSnapshot.decode(JSONSerialization.data(withJSONObject:changed(original,["resources","processes","0","cpu_percent"],250.5)))
        check("process-cpu-exceeds-100-valid",high.resources.processes[0].cpu_percent==250.5)
        let nullable=try ControlPlaneSnapshot.decode(JSONSerialization.data(withJSONObject:changed(changed(original,["runtime","started_at_ms"],NSNull()),["runtime","uptime_seconds"],NSNull())))
        check("runtime-before-run-nullable",nullable.runtime.started_at_ms==nil && nullable.runtime.uptime_seconds==nil)
        let page=try ControlLogResponse.decode(Data(ControlFixtures.logs.utf8))
        check("redacted-log-page",page.records.count==3)
        let logs=try JSONSerialization.jsonObject(with:Data(ControlFixtures.logs.utf8))
        for (name,path,value) in [("free-text-event",["records","0","event"],"raw-secret" as Any),("free-text-code",["records","0","code"],"raw-secret" as Any),("duplicate-sequence",["records","1","sequence"],1 as Any),("bad-app-id",["records","0","app_id"],"secret\nvalue" as Any),("cursor-bound",["next_cursor"],String(repeating:"x",count:65) as Any)] {
            do { _=try ControlLogResponse.decode(JSONSerialization.data(withJSONObject:changed(logs,path,value)));check("reject-log-"+name,false) } catch { check("reject-log-"+name,true) }
        }
        let exported=try ControlLogExport.filtered(page.records)
        let exportPacket:[String:Any]=["schema_version":2,"redaction_version":1,"format":"jsonl","content":String(decoding:exported.content,as:UTF8.self),"records_count":exported.count,"next_cursor":NSNull(),"more":false,"truncated":false,"max_bytes":65536]
        let decoded=try ControlLogExport.decode(JSONSerialization.data(withJSONObject:exportPacket));check("strict-jsonl-export",decoded.count==3 && decoded.content==exported.content)
        var oversized=exportPacket;oversized["content"]=String(repeating:" ",count:65537)
        do {_=try ControlLogExport.decode(JSONSerialization.data(withJSONObject:oversized));check("reject-export-byte-bound",false)}catch{check("reject-export-byte-bound",true)}
        var countMismatch=exportPacket;countMismatch["records_count"]=4
        do {_=try ControlLogExport.decode(JSONSerialization.data(withJSONObject:countMismatch));check("reject-export-count-mismatch",false)}catch{check("reject-export-count-mismatch",true)}
        let vault=InMemoryCredentialVault();let reference=try await vault.save(dummyValue:"demo-unit-value",for:.demo)
        check("dummy-memory-reference",await vault.contains(reference));try await vault.removeLocally(reference)
        check("local-remove-no-provider-revoke",!(await vault.contains(reference)))
        do {_=try await vault.save(dummyValue:"real-looking-value",for:.demo);check("reject-real-value-in-demo",false)}catch{check("reject-real-value-in-demo",true)}
        do {_=try await vault.save(dummyValue:"demo-unit-value",for:.init(service:"unconfirmed",purpose:"unknown"));check("reject-unconfirmed-purpose",false)}catch{check("reject-unconfirmed-purpose",true)}
        let client=ARLClient(home:URL(fileURLWithPath:"/tmp/no-control-test"),app:"friday")
        do {_=try await client.settingsMetadata(.snapshot);check("typed-client-owner-restriction",false)}catch let e as ARLError{check("typed-client-owner-restriction",e.code=="method_not_authorized")}
        let settings=ARLClient(home:URL(fileURLWithPath:"/tmp/no-control-test"),app:"settings")
        do {_=try await settings.settingsMetadata(.logs,params:["path":.string("synthetic")]);check("typed-client-reject-path",false)}catch let e as ARLError{check("typed-client-reject-path",e.code=="invalid_arguments")}
        if CommandLine.arguments.count==3 && CommandLine.arguments[1]=="--fixtures" {
            let fixtures:[String:Any] = ["snapshot":original,"logs":logs,"overview":try JSONSerialization.jsonObject(with:Data(SettingsService.fixture.utf8))]
            try JSONSerialization.data(withJSONObject:fixtures,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        }
        let passed=cases.allSatisfy {$0["passed"] as? Bool == true}
        let result:[String:Any]=["cases":cases,"count":cases.count,"passed":passed,"keychain_access":false]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        if !passed { exit(1) }
    }
}
