import Foundation
import Darwin

struct ARLError: Error { let code: String }
@main struct CodexPackageSettingsTests {
    @MainActor static func main() throws {
        let home = URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        func write<T:Encodable>(_ name:String,_ value:T) throws {
            try RemindersNativeIO.atomicWrite(JSONEncoder().encode(value),to:home.appendingPathComponent(name).path)
        }
        func bytes() throws -> Data { try Data(contentsOf:home.appendingPathComponent("packages-v2.json")) }
        let a = CodexExecutionModel(model:"synthetic-a",display_name:"A",description:"",default_effort:"high",
            efforts:[.init(id:"high",description:""),.init(id:"ultra",description:"")],fast_available:true,fast_description:"")
        let b = CodexExecutionModel(model:"synthetic-b",display_name:"B",description:"",default_effort:"low",
            efforts:[.init(id:"low",description:"")],fast_available:false,fast_description:"")
        var catalog = CodexPackagesCatalog(schema_version:2,catalog_version:"catalog-1",models:[a,b],
            refreshed_at_ms:Int64(Date().timeIntervalSince1970*1000),current:.init(model:a.model,reasoning_effort:"high",service_tier:"default"))
        let original = Dictionary(uniqueKeysWithValues:CodexPackageSettingsStore.ids.map { ($0,CodexPackageRow(display_name:$0,model:a.model,reasoning_effort:"high",service_tier:nil)) })
        try write("catalog-v2.json",catalog)
        try write("packages-v2.json",CodexPackagesFile(schema_version:2,revision:1,catalog_version:catalog.catalog_version,packages:original))
        let settings = CodexPackageSettingsStore(home:home,enabled:true)
        settings.reload();precondition(settings.valid && !settings.changed && settings.draft == original)
        settings.draft["medium"]?.service_tier = "fast"
        settings.selectModel(b.model,for:"medium")
        precondition(settings.draft["medium"]?.reasoning_effort == "low" && settings.draft["medium"]?.tier == "default")
        precondition(settings.draft["high"] == original["high"],"another package was changed")
        settings.draft["medium"]?.display_name = "自定义中档"
        precondition(settings.save() && !settings.changed && settings.saved?.revision == 2)
        let saved = try JSONDecoder().decode(CodexPackagesFile.self,from:bytes())
        precondition(saved.packages["medium"]?.model == b.model && saved.packages["high"]?.service_tier == nil)
        var info = stat();precondition(lstat(home.appendingPathComponent("packages-v2.json").path,&info)==0 && info.st_mode & 0o077 == 0)
        settings.draft["high"]?.display_name = "未保存草稿"
        catalog.catalog_version = "catalog-2"
        let extra = CodexExecutionModel(model:"new-from-codex",display_name:"New",description:"",default_effort:"future-effort",
            efforts:[.init(id:"future-effort",description:"")],fast_available:false,fast_description:"")
        catalog.models.append(extra);try write("catalog-v2.json",catalog)
        settings.reload(preservingDraft:true)
        precondition(settings.draft["high"]?.display_name == "未保存草稿" && settings.catalog?.models.last?.model == extra.model)
        precondition(settings.catalog?.models[0].efforts.last?.id == "ultra","provider effort was filtered out")
        let beforeRemoved = try bytes()
        catalog.models.removeAll { $0.model == b.model };try write("catalog-v2.json",catalog)
        settings.reload(preservingDraft:true)
        precondition(!settings.valid && !settings.save() && settings.draft["medium"]?.model == b.model)
        let afterRemoved = try bytes();precondition(afterRemoved == beforeRemoved,"removed model silently rewrote user choice")
        catalog.models.append(b);try write("catalog-v2.json",catalog);settings.reload()
        let other = CodexPackageSettingsStore(home:home,enabled:true);other.reload()
        settings.draft["high"]?.display_name = "第一处修改";precondition(settings.save())
        let beforeConflict = try bytes()
        other.draft["low"]?.display_name = "第二处草稿"
        precondition(!other.save() && other.draft["low"]?.display_name == "第二处草稿")
        let afterConflict = try bytes();precondition(afterConflict == beforeConflict,"stale writer overwrote new revision")
        other.reload(preservingDraft:true)
        precondition(other.draft["low"]?.display_name == "第二处草稿" && other.draft["high"]?.display_name == "第一处修改",
                     "automatic reload must merge remote changes without losing the user's draft")
        precondition(other.saved?.revision == settings.saved?.revision,"rebased draft must be saveable without a manual reload action")
        other.setParallel(3);precondition(other.maxParallel == 3)
        let parallel=try JSONDecoder().decode(ModelSchedulerConfiguration.self,from:Data(contentsOf:home.deletingLastPathComponent().appendingPathComponent("model-scheduler-v1.json")))
        precondition(parallel.schema_version == 1 && parallel.max_parallel == 3)
        settings.reload();settings.draft["low"]?.display_name = "过期不保存"
        catalog.refreshed_at_ms = Int64((Date().timeIntervalSince1970-120)*1000)
        try write("catalog-v2.json",catalog)
        let staleSaved = settings.save();let afterStale = try bytes()
        precondition(!staleSaved && afterStale == beforeConflict,"stale on-disk catalog was accepted")
        catalog.refreshed_at_ms = Int64(Date().timeIntervalSince1970*1000);try write("catalog-v2.json",catalog)
        let disabledHome = home.appendingPathComponent("disabled-fixture")
        let disabled = CodexPackageSettingsStore(home:disabledHome,enabled:false);disabled.reload()
        precondition(disabled.catalog == nil && !disabled.save() && !FileManager.default.fileExists(atPath:disabledHome.path))
        print("PASS package settings: independent choices, provider models/efforts, private atomic save, CAS conflict, stale catalog, draft preservation, removed models, disabled isolation")
    }
}
