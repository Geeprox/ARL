import SwiftUI
import AppKit
import ARLCredentialOnboarding

struct NASServerSetupSnapshot {
    var address = ""
    var port = 445
    var timeoutSeconds = 8
    var saved = false
    var account: String?
    var state = NASServerState()
    var directory: NASDirectoryPage?
    var share: String?
    var authorizedScope: String?
    var busy = false
    var paused = false
    var fault: ARLNASFault?
    var diagnostic: String?
    var binding: NASServerSetupBinding?
}

struct NASServerSetupBinding: Equatable {
    let endpoint: NASServerEndpoint
    let identity: NASCredentialIdentity
}

enum NASServerSetupAction: Equatable {
    case save(address:String,port:Int,timeout:Int)
    case login
    case shares(cursor:String?)
    case directory(share:String,path:String,cursor:String?)
    case authorize(share:String,path:String,wholeShare:Bool)
    case restoreSaved
    case stop
}

@MainActor final class NASServerSetupIntent {
    let id = UUID()
    let action: NASServerSetupAction
    let revision: UInt64
    let expires = ProcessInfo.processInfo.systemUptime + 30
    private var used = false
    init(action:NASServerSetupAction,revision:UInt64) { self.action=action;self.revision=revision }
    func consume() -> Bool {
        guard !used,ProcessInfo.processInfo.systemUptime<expires else{return false}
        used=true;return true
    }
}

@MainActor protocol NASServerSetupOwner: AnyObject {
    func maintainServerConnection() async
    func serverSetupSnapshot() -> NASServerSetupSnapshot
    func beginServerAction(_ action:NASServerSetupAction) -> NASServerSetupIntent?
    @discardableResult func performServerAction(_ intent:NASServerSetupIntent,input:ARLNASCredentialInput?) async -> Bool
}

extension NASServerSetupOwner { func maintainServerConnection() async {} }

@MainActor protocol NASMioSaveSetupOwner: AnyObject {
    var mioSaveDirectory: String? { get }
    func browseMioSaveDirectories(path: String, cursor: String?, expectedScope: ARLNASReadScope) async throws -> NASDirectoryPage
    func setMioSaveDirectory(_ directory: String?, expectedScope: ARLNASReadScope) async throws
}

private struct NASFolderLocation: Equatable {
    let share: String
    let path: String
    var display: String { ([share] + path.split(separator:"/").map(String.init)).joined(separator:" / ") }
}

private enum NASLocationPurpose: String, Identifiable {
    case read, mio
    var id: Self { self }
    var title: String { self == .read ? "读取位置" : "Mio 保存位置" }
}

private struct NASLocationSelection: Identifiable {
    let id = UUID()
    let purpose: NASLocationPurpose
    let readLocation: NASFolderLocation?
    let saveDirectory: String?
    let scope: ARLNASReadScope?
    let binding: NASServerSetupBinding?
}

@MainActor private struct NASFolderPicker: View {
    let purpose: NASLocationPurpose
    let initial: NASFolderLocation?
    let boundary: NASFolderLocation?
    let hasMioSaveDirectory: Bool
    let listShares: (String?) async throws -> (names:[String], nextCursor:String?)
    let listFolders: (NASFolderLocation, String?) async throws -> (names:[String], nextCursor:String?)
    let select: (NASFolderLocation) async throws -> Void
    let disableSave: () async throws -> Void
    let close: (Task<Void,Never>?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var location: NASFolderLocation?
    @State private var entries: [String] = []
    @State private var cursor: String?
    @State private var request: Task<Void,Never>?
    @State private var busy = false
    @State private var saving = false
    @State private var loaded = false
    @State private var wholeShare = false
    @State private var failure: String?

    private func open(_ target: NASFolderLocation?, cursor: String? = nil) async throws {
        let result: (names:[String], nextCursor:String?)
        if let target {
            result = try await listFolders(target, cursor)
        } else {
            result = try await listShares(cursor)
        }
        try Task.checkCancellation()
        if cursor == nil { wholeShare = false }
        location = target
        entries = cursor == nil ? result.names : entries + result.names.filter { !entries.contains($0) }
        self.cursor = result.nextCursor
        loaded = true
    }

    private func perform(saving: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; self.saving = saving; failure = nil
        request = Task {
            defer { busy = false; self.saving = false; request = nil }
            do { try await action() }
            catch is CancellationError {}
            catch {
                switch error as? ARLNASFault {
                case .bindingMismatch, .sourceChanged: failure = "NAS 设置已更改，请关闭后重新打开选择器。"
                case .userCancelled: failure = "NAS 已暂停，请先连接网络硬盘。"
                case .operationInProgress: failure = "NAS 正在处理其他请求，请稍后重试。"
                default: failure = saving ? "无法更改位置，请检查 NAS 连接后重试。"
                    : "暂时无法打开此位置，请检查 NAS 连接后重试。"
                }
            }
        }
    }

    private var current: NASFolderLocation? { loaded ? location : initial }
    private var requiresWholeShare: Bool { purpose == .read && location?.path == "" && location != initial }
    private var parent: NASFolderLocation? {
        guard let current, !current.path.isEmpty, current != boundary else { return nil }
        return NASFolderLocation(share:current.share,path:current.path.split(separator:"/").dropLast().joined(separator:"/"))
    }
    private var canGoUp: Bool { parent != nil || (purpose == .read && current != nil) }
    private var footerMessage: String? {
        if purpose == .mio { return "Mio 可以在此文件夹中新建文件。已有文件不会被覆盖。" }
        if hasMioSaveDirectory, let location, location != initial {
            return "更改读取位置后，需要重新选择 Mio 保存位置。"
        }
        return nil
    }

    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("选择\(purpose.title)").font(.headline)
            HStack(spacing:10) {
                if canGoUp {
                    Button("上一级",systemImage:"chevron.up") { perform { try await open(parent) } }
                        .disabled(busy)
                }
                Label(current?.display ?? "共享文件夹",systemImage:current == nil ? "externaldrive" : "folder")
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(current?.display ?? "共享文件夹")
                Spacer(minLength:0)
                ProgressView().controlSize(.small).opacity(busy ? 1 : 0)
                    .accessibilityLabel(saving ? "正在保存位置" : "正在读取网络硬盘")
                    .accessibilityHidden(!busy)
            }
            List {
                ForEach(entries,id:\.self) { entry in
                    let share = location == nil
                    Button {
                        let folder = NASFolderLocation(share:location?.share ?? entry,path:share ? "" : entry)
                        perform { try await open(folder) }
                    } label: {
                        HStack(spacing:10) {
                            Label(share ? entry : (entry.split(separator:"/").last.map(String.init) ?? entry),
                                  systemImage:share ? "externaldrive" : "folder")
                            Spacer(minLength:0)
                            Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .frame(minHeight:36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if let cursor {
                    Button(location == nil ? "显示更多共享文件夹" : "显示更多文件夹") {
                        perform { try await open(location,cursor:cursor) }
                    }
                }
                if loaded && entries.isEmpty && cursor == nil {
                    Text(location == nil ? "没有可访问的共享文件夹" : "没有子文件夹").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain).frame(height:220).disabled(busy)
            if requiresWholeShare { Toggle("读取此共享下的全部文件夹",isOn:$wholeShare).disabled(busy) }
            if let footerMessage {
                Text(footerMessage).font(.callout).foregroundStyle(.secondary)
            }
            if let failure {
                HStack {
                    Text(failure).font(.callout).foregroundStyle(.secondary)
                    if !loaded { Button("重试") { perform { try await open(current) } } }
                }
            }
            HStack {
                if purpose == .mio && hasMioSaveDirectory {
                    Button("停用 Mio 保存") { perform(saving:true) { try await disableSave(); dismiss() } }
                        .disabled(busy)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("使用此位置") {
                    guard let location else { return }
                    perform(saving:true) { try await select(location); dismiss() }
                }
                .buttonStyle(EditorialActionButtonStyle(emphasis:.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(busy || !loaded || location == nil || (requiresWholeShare && !wholeShare))
            }
        }
        .padding(24).frame(minWidth:420,idealWidth:500,maxWidth:640)
        .onAppear { perform { try await open(initial) } }
        .onDisappear { request?.cancel(); close(request) }
        .interactiveDismissDisabled(saving)
    }
}

@MainActor protocol NASArchivePickerOwner: NASServerSetupOwner {
    func archiveDestination() async throws -> NASArchiveDestination
    func connectArchive(_ destination: NASArchiveDestination) async throws -> NASArchiveMount
}

@MainActor final class NASServerSetupModel: ObservableObject {
    let owner: any NASServerSetupOwner
    @Published var snapshot: NASServerSetupSnapshot
    init(owner:any NASServerSetupOwner) {self.owner=owner;snapshot=owner.serverSetupSnapshot()}
    func refresh(){snapshot=owner.serverSetupSnapshot()}
    func maintain() async {await owner.maintainServerConnection();refresh()}
    func begin(_ action:NASServerSetupAction) -> NASServerSetupIntent? {
        let intent=owner.beginServerAction(action);refresh();return intent
    }
    @discardableResult func run(_ intent:NASServerSetupIntent,input:ARLNASCredentialInput?=nil) async -> Bool {
        defer{input?.clear();refresh()}
        return await owner.performServerAction(intent,input:input)
    }
}

@MainActor struct NASServerSetupSections: View {
    @ObservedObject var setup: ARLNASSetupModel
    @StateObject private var model: NASServerSetupModel
    @State private var username=""
    @State private var password=""
    @State private var editingLogin=false
    @State private var loginFailure:String?
    @State private var editingDevice=false
    @State private var locationSelection: NASLocationSelection?
    @State private var readPreviewNeedsRestore=false
    @State private var restoringLocation=false
    @StateObject private var discovery=NASDiscoveryModel()
    @State private var task:Task<Void,Never>?
    init(owner:any NASServerSetupOwner,setup:ARLNASSetupModel) {
        self.setup=setup;_model=StateObject(wrappedValue:NASServerSetupModel(owner:owner))
    }
    private var showsLocationAction: Bool {
        model.snapshot.saved && !editingDevice && setup.snapshot.configuration != nil
    }
    private func launch(_ action:NASServerSetupAction) {
        guard !restoringLocation,let intent=model.begin(action) else{return}
        setup.refreshCachedStatus()
        task=Task {
            let succeeded=await model.run(intent)
            if succeeded, !Task.isCancelled, action == .login, needsReadLocation {
                chooseLocation(.read)
            }
            setup.refreshCachedStatus()
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(spacing:12) {
                Image(systemName:"externaldrive.connected.to.line.below").font(.system(size:23)).frame(width:32,height:32).foregroundStyle(.secondary)
                Text("网络硬盘").font(.headline);Spacer()
                ConnectionIndicator(ready:setup.snapshot.connected == .verified,
                    pending:model.snapshot.busy || setup.isPerforming,title:"网络硬盘",inactive:model.snapshot.paused,
                    text:model.snapshot.busy || setup.isPerforming ? "连接中":model.snapshot.paused ? "已暂停":nil)
            }
            if !model.snapshot.saved || editingDevice {
                VStack(alignment:.leading,spacing:12) {
                    Text("选择网络硬盘").font(.callout.weight(.semibold))
                    NASDiscoverySection(discovery:discovery,setup:setup)
                    TextField("设备地址，例如 nas.local",text:$setup.draft.address).accessibilityLabel("NAS 设备地址")
                }
            }
            if model.snapshot.saved && !editingDevice {
                Grid(alignment:.leading,horizontalSpacing:24,verticalSpacing:18) {
                    GridRow {rowTitle("设备");Text(deviceTitle).font(.callout.weight(.medium)).frame(maxWidth:.infinity,alignment:.leading)}
                    GridRow {
                        rowTitle("登录账号")
                        HStack(spacing:10) {
                            Text(model.snapshot.account ?? "账号已保存").font(.callout)
                            Label("已保存",systemImage:"lock.fill").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("更换账号") {username=model.snapshot.account ?? "";editingLogin=true}.controlSize(.small).disabled(model.snapshot.busy)
                        }
                    }
                    if let configuration=setup.snapshot.configuration {
                        locationRow(.read, location:NASFolderLocation(share:configuration.share,path:configuration.root))
                        if let saveOwner = model.owner as? any NASMioSaveSetupOwner {
                            locationRow(.mio, location:saveOwner.mioSaveDirectory.map {
                                NASFolderLocation(share:configuration.share,path:joinPath(configuration.root,$0))
                            })
                        }
                    }
                }
            }
            if !model.snapshot.saved || !sameEndpoint || editingLogin || editingDevice {
                VStack(alignment:.leading,spacing:12) {
                    Text(model.snapshot.saved ? "更新登录":"登录网络硬盘").font(.callout.weight(.semibold))
                    TextField("账号",text:$username).accessibilityLabel("NAS 账号")
                        .disabled(model.snapshot.busy)
                    SecureField("密码",text:$password).accessibilityLabel("NAS 密码")
                        .disabled(model.snapshot.busy)
                    if let loginFailure {
                        EditorialNotice(title:loginFailure,detail:"",symbol:"exclamationmark.circle",color:.orange)
                    }
                    HStack {
                        if model.snapshot.saved {Button("取消") {resetEditing()}.disabled(model.snapshot.busy)}
                        Spacer()
                        Button("保存并连接") {saveLogin()}
                            .buttonStyle(EditorialActionButtonStyle(emphasis:.primary))
                            .disabled(model.snapshot.busy || username.isEmpty || password.isEmpty || (try? NASAddressInput(setup.draft.address,port:setup.draft.port)) == nil)
                    }
                }
            }
            if model.snapshot.paused {
                HStack {
                    Label("连接已暂停",systemImage:"pause.circle").foregroundStyle(.secondary)
                    Spacer();Button("连接网络硬盘") {launch(setup.snapshot.readScope == nil ? .login : .restoreSaved)}
                }
            } else if !model.snapshot.busy,let fault=model.snapshot.fault,setup.snapshot.connected != .verified {
                HStack(alignment:.top,spacing:12) {
                    Label(recovery(fault),systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    if fault != .locationMissing || !showsLocationAction {
                        Button("重新连接") {reconnect()}.disabled(!model.snapshot.saved || !sameEndpoint)
                    }
                }
            }
            if needsReadLocation && locationSelection == nil {
                Button("选择读取位置…") { chooseLocation(.read) }.disabled(model.snapshot.busy || restoringLocation)
            }
            if model.snapshot.saved || editingDevice {
                Divider()
                HStack(alignment:.center,spacing:18) {
                    VStack(alignment:.leading,spacing:5) {
                        Text("连接设置").font(.caption.weight(.medium))
                        Text("SMB · 端口 \(model.snapshot.port) · 超时 \(model.snapshot.timeoutSeconds) 秒").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("管理连接") {
                        Button("更换设备…") {editingDevice=true;username=model.snapshot.account ?? ""}
                        Button("更改连接参数…") {editingDevice=true;username=model.snapshot.account ?? ""}
                        if setup.snapshot.connected == .verified || model.snapshot.state.authenticated {
                            Button("断开连接") {task?.cancel();launch(.stop)}
                        }
                    }.fixedSize().disabled(model.snapshot.busy)
                }
            }
            if editingDevice || !model.snapshot.saved {
                HStack(spacing:16) {
                    VStack(alignment:.leading,spacing:6) {Text("端口").font(.caption).foregroundStyle(.secondary);TextField("445",value:$setup.draft.port,format:.number).frame(width:100)}
                    VStack(alignment:.leading,spacing:6) {Text("连接超时（秒）").font(.caption).foregroundStyle(.secondary);TextField("8",value:$setup.draft.connectionTimeoutSeconds,format:.number).frame(width:120)}
                }
            }
            if !model.snapshot.busy, model.snapshot.fault != nil, let diagnostic = model.snapshot.diagnostic {
                DisclosureGroup("连接详情") {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal:false,vertical:true)
                }
            }
        }
        .onAppear {
            if !model.snapshot.address.isEmpty {setup.draft.address=model.snapshot.address;setup.draft.port=model.snapshot.port;setup.draft.connectionTimeoutSeconds=model.snapshot.timeoutSeconds}
        }
        .onReceive(setup.$snapshot) { _ in model.refresh() }
        .onChange(of:setup.draft.address) {_ in username="";password=""}
        .onChange(of:setup.draft.port) {_ in username="";password=""}
        .onChange(of:needsReadLocation,initial:true) { _, needed in
            if needed && locationSelection == nil && !restoringLocation && !editingDevice { chooseLocation(.read) }
        }
        .sheet(item:$locationSelection) { selection in folderPicker(selection) }
        .onDisappear {
            username="";password="";discovery.cancel()
        }
    }
    private var needsReadLocation: Bool {
        model.snapshot.state.authenticated && model.snapshot.authorizedScope == nil
    }
    private func rowTitle(_ title:String)->some View {Text(title).font(.caption).foregroundStyle(.secondary).frame(width:76,alignment:.leading)}
    private func locationRow(_ purpose: NASLocationPurpose, location: NASFolderLocation?) -> some View {
        GridRow {
            rowTitle(purpose.title)
            HStack(spacing:10) {
                Label(location?.display ?? "未设置",systemImage:"folder")
                    .font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(location?.display ?? "未设置")
                Spacer(minLength:0)
                Button(location == nil ? "选择位置…" : "更改位置…") { chooseLocation(purpose) }
                    .accessibilityLabel((location == nil ? "选择" : "更改") + purpose.title)
                    .controlSize(.small).fixedSize()
                    .disabled(model.snapshot.busy || restoringLocation || setup.isPerforming ||
                              (purpose == .read && model.snapshot.paused) ||
                              (purpose == .mio && setup.snapshot.readScope == nil))
            }
        }
    }
    private var deviceTitle:String {
        let host=(try? NASAddressInput(model.snapshot.address,port:model.snapshot.port).host) ?? model.snapshot.address
        return host.replacingOccurrences(of:".local.",with:"",options:.caseInsensitive).replacingOccurrences(of:".local",with:"",options:.caseInsensitive)
    }
    private func resetEditing() {
        username="";password="";loginFailure=nil;editingDevice=false;editingLogin=false
        setup.draft.address=model.snapshot.address;setup.draft.port=model.snapshot.port;setup.draft.connectionTimeoutSeconds=model.snapshot.timeoutSeconds
    }
    private func saveLogin() {
        guard !restoringLocation,
              let intent=model.begin(.save(address:setup.draft.address,port:setup.draft.port,timeout:setup.draft.connectionTimeoutSeconds))
        else{return}
        let input=ARLNASCredentialInput(username:username,password:password)
        password="";loginFailure=nil
        task=Task {
            let saved=await model.run(intent,input:input)
            if saved {
                await model.maintain()
                if model.snapshot.state.authenticated {
                    username="";editingLogin=false;editingDevice=false
                } else {
                    editingLogin=true
                    loginFailure=model.snapshot.fault.map(recovery) ?? "登录信息已保存，尚未连接网络硬盘"
                }
            } else {
                loginFailure=model.snapshot.fault.map(recovery) ?? "未能保存登录信息"
            }
            setup.refreshCachedStatus()
        }
    }
    private func closeReadPicker(_ previous: Task<Void,Never>?, binding: NASServerSetupBinding?) {
        guard readPreviewNeedsRestore && !restoringLocation else { return }
        readPreviewNeedsRestore=false
        restoringLocation=true
        task=Task {
            await previous?.value
            model.refresh()
            if model.snapshot.binding == binding {
                let action:NASServerSetupAction=setup.snapshot.configuration == nil ? .stop : .restoreSaved
                if let restore=model.begin(action) {await model.run(restore)}
            }
            setup.refreshCachedStatus()
            restoringLocation=false
        }
    }
    private func reconnect() {
        guard !restoringLocation else{return}
        if setup.snapshot.configuration != nil {
            setup.refreshCachedStatus()
            if let configuration=setup.snapshot.configuration {setup.draft=ARLNASConfigurationDraft(configuration:configuration)}
            guard let intent=setup.beginManualActionAfterClick(.testConnection) else{return}
            task=Task {await setup.performAfterClick(intent);model.refresh()}
        } else {launch(.login)}
    }
    private func joinPath(_ root: String, _ path: String) -> String {
        [root,path].filter { !$0.isEmpty }.joined(separator:"/")
    }
    private func chooseLocation(_ purpose: NASLocationPurpose) {
        guard locationSelection == nil else { return }
        let read = setup.snapshot.configuration.map { NASFolderLocation(share:$0.share,path:$0.root) }
        let saveOwner = model.owner as? any NASMioSaveSetupOwner
        locationSelection = NASLocationSelection(purpose:purpose,readLocation:read,saveDirectory:saveOwner?.mioSaveDirectory,
                                                 scope:setup.snapshot.readScope,binding:model.snapshot.binding)
    }
    @ViewBuilder private func folderPicker(_ selection: NASLocationSelection) -> some View {
        let purpose = selection.purpose
        let saveDirectory = selection.saveDirectory
        let saveOwner = model.owner as? any NASMioSaveSetupOwner
        if purpose == .mio, let boundary = selection.readLocation, let saveOwner, let scope = selection.scope {
            let initial = NASFolderLocation(share:boundary.share,path:joinPath(boundary.path,saveDirectory ?? ""))
            NASFolderPicker(purpose:purpose,initial:initial,boundary:boundary,hasMioSaveDirectory:saveDirectory != nil,
                listShares:{ _ in throw ARLNASFault.bindingMismatch },
                listFolders:{ location, cursor in
                    let relative = try relativePath(location, within:boundary)
                    let page = try await saveOwner.browseMioSaveDirectories(path:relative,cursor:cursor,expectedScope:scope)
                    return (page.directories.map { joinPath(boundary.path,$0) }, page.nextCursor)
                },
                select:{ location in
                    try await saveOwner.setMioSaveDirectory(relativePath(location,within:boundary),expectedScope:scope)
                    model.refresh(); setup.refreshCachedStatus()
                },
                disableSave:{ try await saveOwner.setMioSaveDirectory(nil,expectedScope:scope); model.refresh(); setup.refreshCachedStatus() },
                close:{ _ in })
        } else if purpose == .read {
            let binding = selection.binding
            NASFolderPicker(purpose:purpose,initial:selection.readLocation,boundary:nil,hasMioSaveDirectory:saveDirectory != nil,
                listShares:{ try await readShares($0,binding:binding) },listFolders:{ location, cursor in
                    let page = try await readFolders(location,cursor,binding:binding)
                    return (page.directories,page.nextCursor)
                },
                select:{ location in
                    if model.snapshot.share != location.share || model.snapshot.directory?.path != location.path {
                        _ = try await readFolders(location,nil,binding:binding)
                    }
                    try await readAction(.authorize(share:location.share,path:location.path,wholeShare:location.path.isEmpty),binding:binding)
                    readPreviewNeedsRestore=false
                    setup.refreshCachedStatus()
                },
                disableSave:{},close:{ closeReadPicker($0,binding:binding) })
        }
    }
    private func relativePath(_ location: NASFolderLocation, within boundary: NASFolderLocation) throws -> String {
        guard location.share == boundary.share else { throw ARLNASFault.bindingMismatch }
        if boundary.path.isEmpty { return location.path }
        if location.path == boundary.path { return "" }
        let prefix = boundary.path + "/"
        guard location.path.hasPrefix(prefix) else { throw ARLNASFault.bindingMismatch }
        return String(location.path.dropFirst(prefix.count))
    }
    private func readAction(_ action: NASServerSetupAction, binding: NASServerSetupBinding?) async throws {
        try Task.checkCancellation()
        model.refresh()
        guard binding != nil, model.snapshot.binding == binding else { throw ARLNASFault.bindingMismatch }
        guard let intent = model.begin(action) else { throw model.snapshot.fault ?? ARLNASFault.operationInProgress }
        readPreviewNeedsRestore=true
        guard await model.run(intent) else { throw model.snapshot.fault ?? ARLNASFault.connectionFailed }
        try Task.checkCancellation()
    }
    private func readShares(_ cursor: String?, binding: NASServerSetupBinding?) async throws -> (names:[String], nextCursor:String?) {
        if !model.snapshot.state.authenticated { try await readAction(.login,binding:binding) }
        try await readAction(.shares(cursor:cursor),binding:binding)
        return (model.snapshot.state.shares.map(\.name), model.snapshot.state.nextCursor)
    }
    private func readFolders(_ location: NASFolderLocation, _ cursor: String?, binding: NASServerSetupBinding?) async throws -> NASDirectoryPage {
        if !model.snapshot.state.authenticated || !model.snapshot.state.shares.contains(where: { $0.name == location.share }) {
            var shares = try await readShares(nil,binding:binding)
            while !shares.names.contains(location.share), let next = shares.nextCursor {
                shares = try await readShares(next,binding:binding)
            }
        }
        try await readAction(.directory(share:location.share,path:location.path,cursor:cursor),binding:binding)
        guard let page = model.snapshot.directory else { throw ARLNASFault.locationMissing }
        return page
    }
    private func recovery(_ fault:ARLNASFault) -> String {
        switch fault {
        case .authenticationFailed,.credentialInvalid: return "登录失败，请核对账号密码"
        case .credentialNotSaved: return "请先保存账号密码"
        case .credentialsUnavailable: return "连接未完成，请查看详情"
        case .accessDenied,.readDenied: return "访问被拒，请核对服务器权限"
        case .locationMissing: return showsLocationAction ? "找不到已保存的读取位置，请更改位置" : "找不到已保存的读取位置"
        case .transportTimeout: return "连接超时，请核对地址和网络"
        case .bindingMismatch,.sourceChanged: return "设置已变，请重新选择范围"
        case .expired: return "登录已过期，请重新验证"
        case .userCancelled: return "已取消，可重新验证登录"
        default: return "连接未完成，请重新验证"
        }
    }
    private var sameEndpoint:Bool {
        guard let a=try? NASAddressInput(setup.draft.address,port:setup.draft.port),let b=try? NASAddressInput(model.snapshot.address,port:model.snapshot.port) else{return false}
        return a.host.lowercased()==b.host.lowercased() && a.port==b.port
    }
}
