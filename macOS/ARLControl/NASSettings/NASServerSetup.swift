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
    func performServerAction(_ intent:NASServerSetupIntent,input:ARLNASCredentialInput?) async
}

extension NASServerSetupOwner { func maintainServerConnection() async {} }

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
    func run(_ intent:NASServerSetupIntent,input:ARLNASCredentialInput?=nil) async {
        defer{input?.clear();refresh()}
        await owner.performServerAction(intent,input:input)
    }
}

@MainActor struct NASServerSetupSections: View {
    @ObservedObject var setup: ARLNASSetupModel
    @StateObject private var model: NASServerSetupModel
    @State private var username=""
    @State private var password=""
    @State private var wholeShare=false
    @State private var editingLogin=false
    @State private var editingDevice=false
    @State private var choosingLocation=false
    @StateObject private var discovery=NASDiscoveryModel()
    @State private var task:Task<Void,Never>?
    @State private var taskIsPreview=false
    init(owner:any NASServerSetupOwner,setup:ARLNASSetupModel) {
        self.setup=setup;_model=StateObject(wrappedValue:NASServerSetupModel(owner:owner))
    }
    private func launch(_ action:NASServerSetupAction) {
        guard let intent=model.begin(action) else{return}
        setup.refreshCachedStatus()
        switch action {case .directory,.shares:taskIsPreview=true;default:taskIsPreview=false}
        task=Task {
            await model.run(intent)
            if action == .login,choosingLocation,model.snapshot.state.authenticated,
               let browse=model.begin(.shares(cursor:nil)) {await model.run(browse)}
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
                        GridRow {
                            rowTitle("读取位置")
                            HStack(spacing:10) {
                                Label(configuration.share+(configuration.root.isEmpty ? " / 全部文件夹":" / "+configuration.root),systemImage:"folder").lineLimit(2).textSelection(.enabled)
                                Spacer()
                                Button("更改位置") {choosingLocation=true;launch(.login)}.controlSize(.small).disabled(model.snapshot.busy)
                            }
                        }
                    }
                }
            }
            if !model.snapshot.saved || !sameEndpoint || editingLogin || editingDevice {
                VStack(alignment:.leading,spacing:12) {
                    Text(model.snapshot.saved ? "更新登录":"登录网络硬盘").font(.callout.weight(.semibold))
                    TextField("账号",text:$username).accessibilityLabel("NAS 账号")
                    SecureField("密码",text:$password).accessibilityLabel("NAS 密码")
                    HStack {
                        if model.snapshot.saved {Button("取消") {resetEditing()}}
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
                    Spacer();Button("连接网络硬盘") {launch(.login)}
                }
            } else if !model.snapshot.busy,let fault=model.snapshot.fault,setup.snapshot.connected != .verified {
                HStack(alignment:.top,spacing:12) {
                    Label(recovery(fault),systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    Button("重新连接") {reconnect()}.disabled(!model.snapshot.saved || !sameEndpoint)
                }
            }
            if model.snapshot.state.authenticated && (choosingLocation || model.snapshot.authorizedScope == nil) {
                locationPicker
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
            if let diagnostic=model.snapshot.diagnostic,model.snapshot.fault != nil {
                Text("连接返回："+diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            }
        }.disabled(model.snapshot.busy && taskIsPreview)
        .onAppear {
            if !model.snapshot.address.isEmpty {setup.draft.address=model.snapshot.address;setup.draft.port=model.snapshot.port;setup.draft.connectionTimeoutSeconds=model.snapshot.timeoutSeconds}
        }
        .task {while !Task.isCancelled {await model.maintain();do{try await Task.sleep(for:.seconds(5))}catch{return}}}
        .onChange(of:setup.draft.address) {_ in username="";password="";wholeShare=false}
        .onChange(of:setup.draft.port) {_ in username="";password="";wholeShare=false}
        .onChange(of:setup.snapshot.connected) {_ in if setup.snapshot.connected == .verified {choosingLocation=false}}
        .onDisappear {
            username="";password="";discovery.cancel()
            if choosingLocation,setup.snapshot.configuration != nil {
                choosingLocation=false
                let previous=task;previous?.cancel()
                Task {await previous?.value;if let restore=model.begin(.restoreSaved) {await model.run(restore)};setup.refreshCachedStatus()}
            } else if taskIsPreview {task?.cancel()}
        }
    }
    private func rowTitle(_ title:String)->some View {Text(title).font(.caption).foregroundStyle(.secondary).frame(width:76,alignment:.leading)}
    private var deviceTitle:String {
        let host=(try? NASAddressInput(model.snapshot.address,port:model.snapshot.port).host) ?? model.snapshot.address
        return host.replacingOccurrences(of:".local.",with:"",options:.caseInsensitive).replacingOccurrences(of:".local",with:"",options:.caseInsensitive)
    }
    private func resetEditing() {
        username="";password="";editingDevice=false;editingLogin=false
        setup.draft.address=model.snapshot.address;setup.draft.port=model.snapshot.port;setup.draft.connectionTimeoutSeconds=model.snapshot.timeoutSeconds
    }
    private func saveLogin() {
        guard let intent=model.begin(.save(address:setup.draft.address,port:setup.draft.port,timeout:setup.draft.connectionTimeoutSeconds)) else{return}
        let input=ARLNASCredentialInput(username:username,password:password);username="";password="";taskIsPreview=false
        task=Task {await model.run(intent,input:input);await model.maintain();setup.refreshCachedStatus();if model.snapshot.saved {editingLogin=false;editingDevice=false}}
    }
    private func reconnect() {
        if setup.snapshot.configuration != nil {
            setup.refreshCachedStatus()
            if let configuration=setup.snapshot.configuration {setup.draft=ARLNASConfigurationDraft(configuration:configuration)}
            guard let intent=setup.beginManualActionAfterClick(.testConnection) else{return}
            taskIsPreview=false;task=Task {await setup.performAfterClick(intent);model.refresh()}
        } else {launch(.login)}
    }
    private var locationPicker:some View {
        VStack(alignment:.leading,spacing:12) {
            Divider()
            HStack {Text("选择读取位置").font(.callout.weight(.semibold));Spacer();if model.snapshot.authorizedScope != nil {Button("取消选择") {choosingLocation=false;launch(.restoreSaved)}}}
            if let page=model.snapshot.directory,let share=model.snapshot.share {
                HStack {Label(share+(page.path.isEmpty ? "":" / "+page.path),systemImage:"folder");Spacer();if !page.path.isEmpty {Button("上一级",systemImage:"arrow.up") {wholeShare=false;launch(.directory(share:share,path:page.path.split(separator:"/").dropLast().joined(separator:"/"),cursor:nil))}.disabled(!canBrowse)}}
                ForEach(page.directories,id:\.self) {path in
                    Button {wholeShare=false;launch(.directory(share:share,path:path,cursor:nil))} label: {
                        HStack {Label(path.split(separator:"/").last.map(String.init) ?? path,systemImage:"folder");Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,10).frame(minHeight:36).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!canBrowse)
                }
                if let cursor=page.nextCursor {Button("更多文件夹") {launch(.directory(share:share,path:page.path,cursor:cursor))}.disabled(!canBrowse)}
                if page.path.isEmpty {Toggle("读取此共享下的全部文件夹",isOn:$wholeShare).disabled(!canBrowse)}
                HStack {Spacer();Button("使用此位置") {launch(.authorize(share:share,path:page.path,wholeShare:wholeShare))}.disabled(!canBrowse || page.path.isEmpty && !wholeShare).buttonStyle(EditorialActionButtonStyle(emphasis:.primary))}
            } else {
                ForEach(model.snapshot.state.shares) {share in
                    Button {wholeShare=false;launch(.directory(share:share.name,path:"",cursor:nil))} label:{HStack {Label(share.name,systemImage:"externaldrive");Spacer();Image(systemName:"chevron.right").font(.caption)}.frame(minHeight:36).contentShape(Rectangle())}.buttonStyle(.plain).disabled(!canBrowse)
                }
                if model.snapshot.state.shares.isEmpty {Text("正在读取共享文件夹…").font(.caption).foregroundStyle(.secondary)}
                if let cursor=model.snapshot.state.nextCursor {Button("更多共享") {launch(.shares(cursor:cursor))}.disabled(!canBrowse)}
            }
        }
    }
    private func recovery(_ fault:ARLNASFault) -> String {
        switch fault {
        case .authenticationFailed,.credentialInvalid: return "登录失败，请核对账号密码"
        case .credentialNotSaved: return "请先保存账号密码"
        case .credentialsUnavailable: return "连接未完成，请查看详情"
        case .accessDenied,.readDenied: return "访问被拒，请核对服务器权限"
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
    private var canBrowse:Bool {sameEndpoint && !model.snapshot.busy && model.snapshot.state.authenticated && !setup.isPerforming}
}
