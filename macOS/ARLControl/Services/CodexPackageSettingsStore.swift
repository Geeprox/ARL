import Foundation
import Observation
import Darwin

@MainActor @Observable final class CodexPackageSettingsStore {
    static let ids = ["low", "medium", "high", "very_high", "highest"]
    let home: URL
    let enabled: Bool
    private(set) var catalog: CodexPackagesCatalog?
    private(set) var saved: CodexPackagesFile?
    var draft: [String:CodexPackageRow] = [:]
    private(set) var message: String?
    var changed: Bool { saved.map { $0.packages != draft } ?? false }
    var valid: Bool {
        guard let catalog, catalog.isFresh(), Set(draft.keys) == Set(Self.ids) else { return false }
        return draft.values.allSatisfy { row in
            (1...40).contains(row.display_name.unicodeScalars.count) && catalog.execution.permits(row.selection)
        }
    }
    init(home: URL, enabled: Bool) { self.home = home; self.enabled = enabled }
    private func read<T:Decodable>(_ type:T.Type, name:String) throws -> T {
        try RemindersNativeIO.privateDirectory(home.path)
        return try JSONDecoder().decode(type, from:RemindersNativeIO.privateFile(home.appendingPathComponent(name).path, limit:131072))
    }
    func reload(preservingDraft: Bool = false) {
        guard enabled else { return }
        do {
            let c = try read(CodexPackagesCatalog.self, name:"catalog-v2.json")
            let p = try read(CodexPackagesFile.self, name:"packages-v2.json")
            guard c.schema_version == 2, c.execution.isValid, p.schema_version == 2,
                  p.revision > 0, Set(p.packages.keys) == Set(Self.ids) else { throw ARLError(code:"package_configuration_invalid") }
            let keepDraft = preservingDraft && changed
            catalog = c
            if !keepDraft { saved = p; draft = p.packages; message = nil }
            else if saved?.revision != p.revision { message = "套餐已在其他位置更新。草稿已保留，请重新读取后再保存。" }
        } catch { message = "暂时无法读取套餐配置，请检查 Codex 连接。" }
    }
    func selectModel(_ model: String, for id: String) {
        guard var row = draft[id], let option = catalog?.models.first(where: { $0.model == model }) else { return }
        let selected = option.selecting(from:row.selection)
        row.model = selected.model; row.reasoning_effort = selected.reasoning_effort
        if selected.service_tier != row.tier { row.service_tier = selected.service_tier }
        draft[id] = row
    }
    @discardableResult func save() -> Bool {
        guard enabled, valid, changed, let saved, let catalog else { return false }
        let path = home.appendingPathComponent("packages.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { message = "无法锁定套餐配置。"; return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1, flock(fd,LOCK_EX | LOCK_NB) == 0
        else { message = "配置正在更新，请稍后保存。"; return false }
        defer { flock(fd,LOCK_UN) }
        do {
            let current = try read(CodexPackagesFile.self,name:"packages-v2.json")
            let c = try read(CodexPackagesCatalog.self,name:"catalog-v2.json")
            guard current.schema_version == 2, current.revision < Int.max, current.revision == saved.revision, current.packages == saved.packages else {
                message = "套餐已被更新，请重新读取后修改。"; return false
            }
            guard c.schema_version == 2, c.catalog_version == catalog.catalog_version, c.isFresh(), c.execution.isValid,
                  draft.values.allSatisfy({ c.execution.permits($0.selection) }) else {
                message = "模型目录已更新或过期，请重新读取。"; return false
            }
            let next = CodexPackagesFile(schema_version:2,revision:current.revision+1,catalog_version:c.catalog_version,packages:draft)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            let data = try encoder.encode(next)
            guard data.count <= 131072 else { throw ARLError(code:"package_configuration_invalid") }
            try RemindersNativeIO.atomicWrite(data,to:home.appendingPathComponent("packages-v2.json").path)
            self.saved = next; message = "已保存，新任务将使用此套餐配置。"; return true
        } catch { message = "保存失败，请重新读取后重试。"; return false }
    }
}
