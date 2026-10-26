import SwiftUI
import AppKit
import ARLCredentialOnboarding

struct NASServerSetupSnapshot {
    var address = ""
    var port = 445
    var timeoutSeconds = 8
    var saved = false
    var state = NASServerState()
    var directory: NASDirectoryPage?
    var share: String?
    var authorizedScope: String?
    var busy = false
    var fault: ARLNASFault?
    var diagnostic: String?
}

enum NASServerSetupAction: Equatable {
    case save(address:String,port:Int,timeout:Int)
    case login
    case shares(cursor:String?)
    case directory(share:String,path:String,cursor:String?)
    case authorize(share:String,path:String,wholeShare:Bool)
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
    func serverSetupSnapshot() -> NASServerSetupSnapshot
    func beginServerAction(_ action:NASServerSetupAction) -> NASServerSetupIntent?
    func performServerAction(_ intent:NASServerSetupIntent,input:ARLNASCredentialInput?) async
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
    @State private var task:Task<Void,Never>?
    @State private var taskIsPreview=false
    init(owner:any NASServerSetupOwner,setup:ARLNASSetupModel) {
        self.setup=setup;_model=StateObject(wrappedValue:NASServerSetupModel(owner:owner))
    }
    private func launch(_ action:NASServerSetupAction) {
        guard let intent=model.begin(action) else{return}
        setup.refreshCachedStatus()
        switch action {case .directory,.shares:taskIsPreview=true;default:taskIsPreview=false}
        task=Task{await model.run(intent);setup.refreshCachedStatus()}
    }
    var body: some View {
        Section("设备地址") {
            TextField("设备地址",text:$setup.draft.address)

        }.disabled(model.snapshot.busy)
        Section("账号登录") {
            TextField("账号",text:$username)
            SecureField("密码",text:$password)

            HStack {
                Button("保存登录") {
                    guard let intent=model.begin(.save(address:setup.draft.address,port:setup.draft.port,timeout:setup.draft.connectionTimeoutSeconds)) else{return}
                    let input=ARLNASCredentialInput(username:username,password:password)
                    username="";password="";taskIsPreview=false
                    task=Task{await model.run(intent,input:input);setup.refreshCachedStatus()}
                }.disabled(model.snapshot.busy || username.isEmpty || password.isEmpty || (try? NASAddressInput(setup.draft.address,port:setup.draft.port)) == nil)
                Button("验证登录") {launch(.login)}
                    .disabled(model.snapshot.busy || !model.snapshot.saved || !sameEndpoint)
                Button("断开连接") {task?.cancel();launch(.stop)}
                    .disabled(!model.snapshot.busy && !model.snapshot.state.authenticated && setup.snapshot.connected != .verified)
            }
            Text(model.snapshot.state.authenticated ? "服务器已验证" : model.snapshot.saved && sameEndpoint ? "登录已保存，尚未验证" : "尚未保存登录").foregroundStyle(.secondary)
            if model.snapshot.saved && sameEndpoint && model.snapshot.authorizedScope == nil {
                Text(model.snapshot.state.authenticated ? "请选择共享和目录。" : "验证已保存的登录后，选择共享和目录。").foregroundStyle(.secondary)
            }
            if let fault=model.snapshot.fault {Text(recovery(fault)).foregroundStyle(.secondary)}
        }
        Section("选择共享") {
            Button("查看共享") {launch(.shares(cursor:nil))}.disabled(!canBrowse)

            ForEach(model.snapshot.state.shares) {share in
                Button(share.name) {wholeShare=false;launch(.directory(share:share.name,path:"",cursor:nil))}
                    .disabled(!canBrowse)
            }
            if let cursor=model.snapshot.state.nextCursor {
                Button("下一页") {launch(.shares(cursor:cursor))}.disabled(!canBrowse)
            }
        }
        if let page=model.snapshot.directory,let share=model.snapshot.share {
            Section("选择目录") {
                Text(share+(page.path.isEmpty ? "" : "/"+page.path)).textSelection(.enabled)

                if !page.path.isEmpty {
                    Button("上一级") {wholeShare=false;launch(.directory(share:share,path:page.path.split(separator:"/").dropLast().joined(separator:"/"),cursor:nil))}.disabled(!canBrowse)
                }
                ForEach(page.directories,id:\.self) {path in
                    Button(path.split(separator:"/").last.map(String.init) ?? path) {wholeShare=false;launch(.directory(share:share,path:path,cursor:nil))}.disabled(!canBrowse)
                }
                if let cursor=page.nextCursor {Button("下一页") {launch(.directory(share:share,path:page.path,cursor:cursor))}.disabled(!canBrowse)}
                if page.path.isEmpty {Toggle("整个共享",isOn:$wholeShare).disabled(!canBrowse)}
                Button("授权目录") {launch(.authorize(share:share,path:page.path,wholeShare:wholeShare))}
                    .disabled(!canBrowse || page.path.isEmpty && !wholeShare)
            }
        }
        if let scope=model.snapshot.authorizedScope {
            Section("已授权") {
                Text(scope).textSelection(.enabled)

                Button("连接目录") {
                    setup.refreshCachedStatus()
                    if let configuration=setup.snapshot.configuration {setup.draft=ARLNASConfigurationDraft(configuration:configuration)}
                    guard let intent=setup.beginManualActionAfterClick(.testConnection) else{return}
                    taskIsPreview=false
                    task=Task{await setup.performAfterClick(intent);model.refresh()}
                }.disabled(model.snapshot.busy || setup.isPerforming)
                Text(setup.snapshot.connected == .verified ? "目录已连接" : "目录尚未连接").foregroundStyle(.secondary)
            }
        }
        Section {
            DisclosureGroup("连接详情") {
                Stepper("端口：\(setup.draft.port)",value:$setup.draft.port,in:1...65535)
                Stepper("超时：\(setup.draft.connectionTimeoutSeconds)秒",value:$setup.draft.connectionTimeoutSeconds,in:1...30)

                if let fault=model.snapshot.fault {Text(fault.rawValue).font(.caption).textSelection(.enabled)}
                if let diagnostic=model.snapshot.diagnostic {Text(diagnostic).font(.caption).textSelection(.enabled)}
            }
        }.disabled(model.snapshot.busy)
        .onAppear {
            if !model.snapshot.address.isEmpty {setup.draft.address=model.snapshot.address;setup.draft.port=model.snapshot.port;setup.draft.connectionTimeoutSeconds=model.snapshot.timeoutSeconds}
        }
        .task {while !Task.isCancelled {model.refresh();try? await Task.sleep(for:.seconds(2))}}
        .onChange(of:setup.draft.address) {_ in username="";password="";wholeShare=false}
        .onChange(of:setup.draft.port) {_ in username="";password="";wholeShare=false}
        .onDisappear {username="";password="";if taskIsPreview {task?.cancel()}}
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
