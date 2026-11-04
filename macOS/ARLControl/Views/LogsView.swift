import SwiftUI
import UniformTypeIdentifiers

struct MetadataLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}
struct LogsView: View {
    let store: RuntimeStore
    @State private var search=""
    @State private var level="all"
    @State private var selected:Int?
    @State private var recent:RecentLogPage?
    @State private var recentError:String?
    @State private var compatibility=false
    @State private var lastRead:Date?
    @State private var context:LogTaskContext?
    @State private var contextLoading=false
    @State private var exporting=false
    @State private var exportData=Data()
    @State private var exportError=false
    @State private var preparing=false
    @FocusState private var focusedRow:Int?
    private var records:[RedactedLogEntry] {recent?.entries ?? store.control.logs.value?.entries ?? []}
    private var filtered:[RedactedLogEntry] {
        records.filter {(level == "all" || $0.level == level) && (search.isEmpty || ($0.searchableText+" "+$0.eventTitle+" "+$0.explanation+" "+appName($0)).localizedCaseInsensitiveContains(search))}.sorted{$0.sequence>$1.sequence}
    }
    private var selectedEntry:RedactedLogEntry? {filtered.first{$0.id==selected}}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                EditorialHeading(title:"运行记录",subtitle:"最近 24 小时的应用连接、任务结果与异常")
                Spacer()
                Menu {
                    if let entry=selectedEntry {Button("导出这条记录") {export([entry])}}
                    Button("导出当前结果") {export(filtered.sorted{$0.sequence<$1.sequence})}.disabled(filtered.isEmpty)
                    Button("导出最近 24 小时") {exportRecent()}
                } label:{Label("导出",systemImage:"square.and.arrow.up")}.disabled(preparing)
            }
            HStack(spacing:12) {
                HStack(spacing:8) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索应用、事件或原因",text:$search).textFieldStyle(.plain).accessibilityLabel("搜索运行记录")
                }.padding(.horizontal,12).frame(height:36)
                    .background(EditorialStyle.panel,in:RoundedRectangle(cornerRadius:6))
                    .overlay {RoundedRectangle(cornerRadius:6).strokeBorder(EditorialStyle.rule,lineWidth:0.5).allowsHitTesting(false)}
                EditorialMenu {
                    Button("全部级别") {level="all"}
                    Button("仅错误") {level="error"}
                    Button("仅警告") {level="warning"}
                    Button("仅信息") {level="info"}
                } label:{Text(level == "error" ? "仅错误":level == "warning" ? "仅警告":level == "info" ? "仅信息":"全部级别")}.frame(width:120).accessibilityLabel("日志级别")
            }
            VStack(spacing:0) {
                HStack(spacing:16) {
                    Text("时间").frame(width:76,alignment:.leading)
                    Text("事件与说明").frame(maxWidth:.infinity,alignment:.leading)
                    Text("应用").frame(width:110,alignment:.leading)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,16).padding(.vertical,12)
                Divider()
                ScrollView {
                    LazyVStack(spacing:0) {
                        ForEach(filtered) {entry in
                            Button {selected=entry.id} label: {
                                HStack(alignment:.top,spacing:16) {
                                    Text(Date(timeIntervalSince1970:Double(entry.at_ms)/1000),format:.dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width:76,alignment:.leading).padding(.top,2)
                                    VStack(alignment:.leading,spacing:5) {
                                        HStack(spacing:7) {Circle().fill(levelColor(entry.level)).frame(width:6,height:6);Text(entry.eventTitle).font(.callout.weight(.medium))}
                                        Text(entry.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                    Text(appName(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).frame(width:110,alignment:.leading).help(appName(entry))
                                }.padding(.horizontal,16).padding(.vertical,12).contentShape(Rectangle())
                            }.buttonStyle(LogEntryButtonStyle(selected:selected==entry.id))
                                .focused($focusedRow,equals:entry.id).focusEffectDisabled()
                                .accessibilityAddTraits(selected==entry.id ? .isSelected:[])
                                .accessibilityElement(children:.ignore)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(entry.eventTitle+"，"+appName(entry)+"，"+entry.explanation)
                            Divider().padding(.horizontal,16)
                        }
                    }.onMoveCommand {direction in
                        if direction == .down {moveSelection(1)}
                        else if direction == .up {moveSelection(-1)}
                    }
                }.overlay {
                    if filtered.isEmpty {
                        VStack(spacing:10) {
                            Image(systemName:recentError == nil ? "list.bullet.rectangle":"exclamationmark.circle").font(.system(size:26,weight:.light)).foregroundStyle(.secondary)
                            Text(recentError != nil ? "运行记录暂时无法读取":records.isEmpty ? "还没有运行记录":"没有符合条件的记录").font(.headline)
                            Text(recentError != nil ? "显示上次载入的内容，稍后会自动重试。":records.isEmpty ? "应用连接、模型任务和异常都会记录在这里。":"换个关键词或调整级别试试。").font(.caption).foregroundStyle(.secondary)
                        }.padding(24)
                    }
                }
            }.modifier(EditorialSurface()).frame(maxHeight:.infinity)
            HStack(spacing:12) {
                Text("\(filtered.count) 条记录").font(.caption).foregroundStyle(.secondary)
                if let lastRead {Text("更新于 \(lastRead.formatted(date:.omitted,time:.shortened))").font(.caption).foregroundStyle(.secondary)}
                if recent?.truncated == true {Text("显示最新 500 条").font(.caption).foregroundStyle(.secondary)}
                if recentError != nil {Text("刷新暂未成功").font(.caption).foregroundStyle(.orange)}
                Spacer()
                if preparing {ProgressView().controlSize(.small)}
            }
        }
        .inspector(isPresented:Binding(get:{selectedEntry != nil},set:{if !$0 {selected=nil}})) {
            if let entry=selectedEntry {detailPanel(entry).inspectorColumnWidth(min:260,ideal:300,max:360)}
        }
        .task {
            while !Task.isCancelled {
                await refreshRecent()
                do {try await Task.sleep(for:.seconds(5))}catch{return}
            }
        }
        .task(id:selectedEntry?.id) {await loadContext()}
        .onChange(of:level) {_,_ in selected=nil}
        .onChange(of:search) {_,_ in if selectedEntry == nil {selected=nil}}
        .fileExporter(isPresented:$exporting,document:MetadataLogDocument(data:exportData),contentType:.plainText,defaultFilename:"ARL-运行记录.jsonl") {result in if case .failure=result {exportError=true};exportData=Data()}
        .alert("导出未完成",isPresented:$exportError) {Button("好",role:.cancel) {}} message:{Text("请缩小筛选范围或更换保存位置后重试。")}
    }
    private func appName(_ entry:RedactedLogEntry)->String {
        guard let id=entry.app_id else{return "ARL 后台"}
        return store.control.registry.value?.first{$0.id==id}?.name ?? AppIdentity.presentation(id).name
    }
    private func detailPanel(_ entry:RedactedLogEntry)->some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("事件详情").font(.headline);Spacer();Button {selected=nil} label:{Image(systemName:"xmark").frame(width:20,height:24)}.buttonStyle(.plain).help("关闭事件详情")}
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text(entry.eventTitle).font(.title3.weight(.semibold))
                    Text(context?.reasonTitle ?? entry.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Divider()
                    detail("发生时间",Date(timeIntervalSince1970:Double(entry.at_ms)/1000).formatted(date:.abbreviated,time:.standard))
                    detail("来源应用",appName(entry))
                    if let context {
                        if let title=context.packageTitle {detail("套餐",title)}
                        if let model=context.model {detail("模型",model)}
                        if let effort=context.reasoning_effort {detail("思考强度",CodexEffortOption.title(effort))}
                        if let duration=context.duration_ms {detail("执行耗时",String(format:"%.1f 秒",Double(duration)/1000))}
                        if let id=context.task_id {detail("任务编号",id)}
                        if let method=context.method {detail("请求的功能",method)}
                    }
                    if contextLoading {ProgressView().controlSize(.small)}
                    else if context?.isEmpty != false {Text("这条记录未保存更详细的任务信息。").font(.caption).foregroundStyle(.secondary)}
                    if let code=entry.code {detail("状态代码",code)}
                    Button("导出这条记录") {export([entry])}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(20).frame(maxHeight:.infinity,alignment:.top).background(EditorialStyle.canvas)
    }
    private func detail(_ title:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:5) {Text(title).font(.caption).foregroundStyle(.secondary);Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
    }
    private func refreshRecent() async {
        guard !store.demo,!compatibility else{return}
        do {
            let result=try await ARLClient(home:store.service.home,app:"settings").rpc("settings.logs.recent.v1",params:["limit":.number(500)],timeout:3)
            let next=try RecentLogPage.decode(JSONEncoder().encode(result))
            guard !Task.isCancelled else{return}
            if recent?.sessionID != next.sessionID {selected=nil}
            recent=next;lastRead=Date();recentError=nil
            if selectedEntry == nil {selected=nil}
        } catch {
            guard !Task.isCancelled else{return}
            let code=(error as? ARLError)?.code ?? "unavailable"
            if code == "unknown_method" || code == "method_not_authorized" {compatibility=true}
            else {recentError=code}
        }
    }
    private func loadContext() async {
        context=nil
        guard let entry=selectedEntry,let session=recent?.sessionID ?? store.logPaging.sessionID,!store.demo else{return}
        contextLoading=true;defer{contextLoading=false}
        do {
            let reply=try await ARLClient(home:store.service.home,app:"settings").rpc("settings.log_details.v1",params:["sequence":.number(Double(entry.sequence)),"session_id":.string(session)],timeout:3)
            let next=try LogTaskContext.decode(JSONEncoder().encode(reply),sequence:entry.sequence,session:session)
            guard !Task.isCancelled,selectedEntry?.id==entry.id else{return};context=next
        } catch { /* Legacy events remain readable with their finite explanation. */ }
    }
    private func levelColor(_ level:String)->Color {level == "error" ? .red:level == "warning" ? .orange:.secondary}
    private func moveSelection(_ offset:Int) {
        guard !filtered.isEmpty else{return}
        let current=filtered.firstIndex{$0.id==selected} ?? (offset>0 ? -1:filtered.count)
        let next=filtered[max(0,min(filtered.count-1,current+offset))].id
        selected=next;focusedRow=next
    }
    private func export(_ rows:[RedactedLogEntry]) {
        do {let result=try ControlLogExport.filtered(rows);exportData=result.content;exporting=true}catch{exportError=true}
    }
    private func exportRecent() {
        preparing=true
        Task {do {let result=try await store.service.exportLogs();exportData=result.content;exporting=true}catch{exportError=true};preparing=false}
    }
}

private struct LogEntryButtonStyle:ButtonStyle {
    let selected:Bool
    @Environment(\.isFocused) private var focused
    @State private var hovered=false
    func makeBody(configuration:Configuration)->some View {
        configuration.label.foregroundStyle(EditorialStyle.graphite)
            .background(selected ? EditorialStyle.accent.opacity(0.07):Color.primary.opacity(configuration.isPressed ? 0.07:hovered ? 0.025:0))
            .overlay {RoundedRectangle(cornerRadius:4).strokeBorder(focused ? EditorialStyle.accent:.clear,lineWidth:1.5).allowsHitTesting(false)}
            .onHover {hovered=$0}
    }
}
