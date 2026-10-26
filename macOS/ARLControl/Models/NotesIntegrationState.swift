import Foundation

/// Imported owner source facts only. This is not an OS permission snapshot.
struct NotesIntegrationRecord: Identifiable, Sendable {
    enum Implementation: String, Sendable { case source_only }
    enum Permission: String, Sendable { case unknown }
    enum RequestRoute: String, Sendable { case provided_not_admitted }
    let id: String
    let title: String
    let implementation: Implementation = .source_only
    let permission: Permission = .unknown
    let requestRoute: RequestRoute = .provided_not_admitted
    var displayExplanation: String {
        switch id {
        case "notes.search.v1": "只在已确认文件夹内查找"
        case "notes.read.v1": "只读取本次创建的备忘录"
        case "notes.create.v2": "只创建一次纯文本笔记并核对"
        default: ""
        }
    }
    static let records: [Self] = [
        .init(id: "notes.search.v1", title: "查找标题"),
        .init(id: "notes.read.v1", title: "核对笔记"),
        .init(id: "notes.create.v2", title: "创建笔记")
    ]
    static let ownerArchiveSHA256 = "190c2b47484ae8d7e778815508f0962f907e551ca8c9283ebd9aa6661f7005ba"
}
