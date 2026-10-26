import SwiftUI
import AppKit
import ARLCredentialOnboarding

public struct ARLNASConfigurationDraft: Equatable {
    public var address = ""
    public var port = 445
    public var transport: ARLNASTransport = .smb
    public var share = ""
    public var root = ""
    public var applicationScope: ARLNASApplicationScope = .readOnly
    public var automaticReadRetries = 0
    public var connectionTimeoutSeconds = 8
    public var maximumConcurrentReads = 1

    public init(configuration: ARLNASConfiguration? = nil) {
        guard let configuration else { return }
        address = configuration.addressInput
        port = configuration.port
        transport = configuration.transport
        share = configuration.share
        root = configuration.root
        applicationScope = configuration.applicationScope
        automaticReadRetries = configuration.advanced.automaticReadRetries
        connectionTimeoutSeconds = configuration.advanced.connectionTimeoutSeconds
        maximumConcurrentReads = configuration.advanced.maximumConcurrentReads
    }

    public func validated() -> Result<ARLNASConfiguration, ARLNASFault> {
        do {
            let advanced = try ARLNASAdvancedOptions(
                automaticReadRetries: automaticReadRetries,
                connectionTimeoutSeconds: connectionTimeoutSeconds,
                maximumConcurrentReads: maximumConcurrentReads)
            return .success(try ARLNASConfiguration(address: address, transport: transport,
                share: share, root: root, applicationScope: applicationScope, advanced: advanced, port: port))
        } catch let fault as ARLNASFault {
            return .failure(fault)
        } catch {
            return .failure(.invalidConfiguration)
        }
    }
}

@MainActor protocol NASDirectoryUIOwner: AnyObject {
    func browseDirectories(path: String, cursor: String?) async throws -> NASDirectoryPage
}

@MainActor protocol NASFileUIOwner: AnyObject {
    func consumeFileRead(_ request: NASFileRequest) async throws -> Data
    func connectSavedReadScope() async throws
    func validateReadContext(sourceRef:String,generation:UInt64,epoch:String) async throws
}

extension NASFileUIOwner {
    func validateReadContext(sourceRef:String,generation:UInt64,epoch:String) async throws {throw ARLNASFault.hostNotConfigured}
}

@MainActor
public final class ARLNASSetupModel: ObservableObject {
    @Published public var draft: ARLNASConfigurationDraft
    @Published public private(set) var snapshot: ARLNASSetupSnapshot
    @Published public private(set) var isPerforming = false
    @Published public private(set) var cleanupPending = false
    @Published public private(set) var lastFault: ARLNASFault?
    @Published public private(set) var uploadMessage: String?
    @Published private var selectedDevice: NASDiscoveredDevice?
    var shareSuggestions: [String] {
        guard let device = selectedDevice, let address = try? NASAddressInput(draft.address, port: draft.port),
              address.port == device.port, address.host == device.host || device.addresses.contains(address.host)
        else { return [] }
        return device.shares
    }
    @Published private(set) var directoryPage: NASDirectoryPage?
    @Published private(set) var directoryMessage: String?
    private var directoryGeneration = UUID()
    private let backend: any ARLNASSetupBackend
    private let credentialConsumer: (any ARLNASCredentialConsumer)?
    private var hasUncertainWrite = false
    private struct PendingAction {
        let request: ARLNASActionRequest
        let callerPins: ARLNASObservedCallerPins?
        let stoppedSaveRequest: ARLNASActionRequest?
    }
    private var pendingActions: [UUID: PendingAction] = [:]
    private var cancelledIntentIDs: Set<UUID> = []
    private var stopIntentID: UUID?

    public init(backend: any ARLNASSetupBackend,
                credentialConsumer: (any ARLNASCredentialConsumer)? = nil) {
        self.backend = backend
        self.credentialConsumer = credentialConsumer
        let cached = backend.cachedSnapshot()
        snapshot = cached
        draft = ARLNASConfigurationDraft(configuration: cached.configuration)
        hasUncertainWrite = cached.writable == .uncertainWrite
    }

    /// Shared owner injection seam; the same native backend selects the saved scope.
    public func consumeFileRead(tool: String, argumentsJSON: Data) async throws -> Data {
        guard let owner = backend as? any NASFileUIOwner else { throw ARLNASFault.hostNotConfigured }
        let request = try NASFileRequest(tool: tool, argumentsJSON: argumentsJSON)
        return try await owner.consumeFileRead(request)
    }
    /// Used by coordinated UI/lifecycle recovery; never widens or replaces a saved root.
    public func connectSavedReadScope() async throws {
        guard let owner = backend as? any NASFileUIOwner else { throw ARLNASFault.hostNotConfigured }
        try await owner.connectSavedReadScope()
        refreshCachedStatus()
    }

    func validateReadContext(sourceRef:String,generation:UInt64,epoch:String) async throws {
        guard let owner=backend as? any NASFileUIOwner else {throw ARLNASFault.hostNotConfigured}
        try await owner.validateReadContext(sourceRef:sourceRef,generation:generation,epoch:epoch)
    }
    var serverSetupOwner: (any NASServerSetupOwner)? { backend as? any NASServerSetupOwner }
    var archivePickerOwner: (any NASArchivePickerOwner)? { backend as? any NASArchivePickerOwner }

    public convenience init() { self.init(backend: ARLNASUnsupportedBackend()) }

    // Never calls perform, a credential consumer or a native API.
    public func refreshCachedStatus() {
        guard !isPerforming else { return }
        let cached = backend.cachedSnapshot()
        guard cached.revision >= snapshot.revision else {
            lastFault = .staleGeneration
            return
        }
        snapshot = cached
        hasUncertainWrite = hasUncertainWrite || cached.writable == .uncertainWrite
    }

    public func admission(for action: ARLNASManualAction) -> ARLNASAdmission {
        if action == .testWrite {
            return hasUncertainWrite ? .held(.writeOutcomeUncertain) : .unsupported(.writeUnsupported)
        }
        let declared = snapshot.availability.admission(for: action)
        guard declared.isAllowed else { return declared }
        if action == .stop {
            guard stopIntentID == nil, !cleanupPending else { return .held(.operationInProgress) }
            return snapshot.configuration != nil && snapshot.readScope != nil
                ? .allowed : .held(.configurationNotSaved)
        }
        guard !isPerforming else { return .held(.operationInProgress) }
        let configuration: ARLNASConfiguration
        switch draft.validated() {
        case .success(let validated): configuration = validated
        case .failure(let fault): return .held(fault)
        }
        if action == .saveConfiguration { return .allowed }
        guard snapshot.configuration == configuration,
              snapshot.configurationSaved == .verified else {
            return .held(.configurationNotSaved)
        }
        if action == .saveCredential {
            return credentialConsumer == nil ? .held(.credentialEntryUnavailable) : .allowed
        }
        guard snapshot.readScope != nil, snapshot.observedCallerPins != nil,
              snapshot.credentialReferenceSaved == .verified else {
            return .held(.credentialNotSaved)
        }
        if action == .testRead {
            guard snapshot.readScope?.configGeneration == snapshot.currentConfigurationGeneration,
                  snapshot.connectionEpoch != nil, snapshot.connected == .verified
            else { return .held(.staleGeneration) }
        } else if snapshot.currentConfigurationGeneration >= UInt64(Int64.max) {
            return .held(.staleGeneration)
        }
        // A reference permits an explicit host attempt, not a claim of availability.
        return .allowed
    }

    // Editing is local view state. Persisting still requires the exact saved target below.
    var canEditCredentialFields: Bool {
        guard !isPerforming, credentialConsumer != nil, snapshot.provider == .available else { return false }
        switch snapshot.availability.saveCredential {
        case .allowed, .held(.configurationNotSaved): return true
        default: return false
        }
    }

    var credentialSaveGuidance: String? {
        guard canEditCredentialFields else {
            return admission(for: .saveCredential).fault?.message ?? ARLNASFault.credentialEntryUnavailable.message
        }
        if draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请先选择设备或填写设备地址；账号和密码可先填写。"
        }
        if draft.share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写共享目录，再点击“保存设置”。共享名可向硬盘管理员确认；修改连接范围会清空已输入的登录信息。"
        }
        if case .failure(let fault) = draft.validated() { return fault.message }
        if admission(for: .saveCredential).fault == .configurationNotSaved {
            return "当前设置尚未保存。请先点击上方“保存设置”，再保存登录；保存设置不会清空已输入的账号和密码。"
        }
        return admission(for: .saveCredential).fault?.message
    }

    func selectDevice(_ device: NASDiscoveredDevice, address: String) {
        guard !isPerforming, address == device.host || device.addresses.contains(address),
              (try? NASAddressInput(address, port: device.port)) != nil else { return }
        invalidateDirectories()
        draft.address = address; draft.port = device.port
        draft.share = ""; draft.root = ""
        selectedDevice = device
    }
    var canBrowseDirectories: Bool {
        backend is any NASDirectoryUIOwner && !isPerforming && snapshot.connected == .verified
            && snapshot.configuration == (try? draft.validated().get())
    }
    func invalidateDirectories() { directoryGeneration = UUID(); directoryPage = nil; directoryMessage = nil }
    func browseDirectoriesAfterClick(path: String = "", cursor: String? = nil) async {
        guard canBrowseDirectories, let owner = backend as? any NASDirectoryUIOwner else { return }
        let captured = directoryGeneration, configuration = snapshot.configuration, epoch = snapshot.connectionEpoch
        isPerforming = true; directoryMessage = nil
        defer { isPerforming = !pendingActions.isEmpty }
        do {
            let page = try await owner.browseDirectories(path: path, cursor: cursor)
            guard captured == directoryGeneration, configuration == (try? draft.validated().get()),
                  epoch == backend.cachedSnapshot().connectionEpoch, !Task.isCancelled else { return }
            directoryPage = page
            if page.directories.isEmpty { directoryMessage = page.nextCursor == nil ? "此页没有子目录。" : "此页没有子目录，可继续查看下一页。" }
        } catch {
            if captured == directoryGeneration && !Task.isCancelled { directoryMessage = "目录读取未完成，请重新连接后再试。" }
        }
    }
    func selectDirectoryAsRoot() {
        guard canBrowseDirectories, let page = directoryPage, !page.path.isEmpty,
              let configuration = snapshot.configuration else { return }
        draft.root = [configuration.root, page.path].filter { !$0.isEmpty }.joined(separator: "/")
        invalidateDirectories()
    }

    public var canTestNewFile: Bool {
        backend is any NASUploadUIOwner && !isPerforming && !hasUncertainWrite
            && snapshot.connected == .verified && snapshot.configuration == (try? draft.validated().get())
    }
    public func uploadTestAfterClick(directory: String) async {
        guard canTestNewFile, let owner = backend as? any NASUploadUIOwner else { return }
        isPerforming = true; defer { isPerforming = false }
        do {
            let proposal = try await owner.prepareUploadTest(directory: directory)
            guard NSApplication.shared.isActive, !Task.isCancelled else { return }
            let alert = NSAlert()
            alert.messageText = "创建测试"
            let config = proposal.configuration
            alert.informativeText = "设备：" + config.host + ":" + String(config.port)
                + "\n共享：" + config.share + "\n目录：" + config.root + "\n新文件：" + proposal.target
                + "\n\n完整内容：\n" + proposal.text
                + "\n仅新建，不覆盖、不自动重试或删除。完成后此文件会保留。"
            alert.addButton(withTitle: "确认创建")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn, !Task.isCancelled else { return }
            let result = try await owner.uploadTestAfterConfirmation(proposal)
            if result.committed {
                uploadMessage = "已写入并回读核对：" + proposal.target
            } else if result.status == "uncertain" {
                hasUncertainWrite = true
                uploadMessage = "写入结果未知，请先核对文件：" + proposal.target + "。不会自动重试或删除。"
            } else {
                uploadMessage = "本次新文件测试未完成。已有文件不会覆盖。"
            }
        } catch {
            uploadMessage = "未能完成新文件测试；请核对连接及测试目录。"
        }
    }

    public func fact(for field: ARLNASStatusField) -> ARLNASFact {
        if field == .writable && hasUncertainWrite { return .uncertainWrite }
        if field == .writable { return snapshot.writable }
        if field == .connected || field == .readable || field == .credentialAvailable {
            if lastFault == .bindingMismatch || lastFault == .staleGeneration || lastFault == .callerRejected {
                return .held(lastFault ?? .bindingMismatch)
            }
        }
        if let saved = snapshot.configuration {
            guard case .success(let current) = draft.validated(), saved == current else {
                return .held(.configurationChanged)
            }
        }
        return snapshot.fact(for: field)
    }

    // Called synchronously in a button closure. Capture the exact request and
    // reserve the action slot before a Task can suspend or another click occurs.
    public func beginManualActionAfterClick(_ action: ARLNASManualAction) -> ARLNASManualIntent? {
        let admission = admission(for: action)
        guard admission.isAllowed else { lastFault = admission.fault; return nil }
        let configuration: ARLNASConfiguration
        if action == .stop, let saved = snapshot.configuration { configuration = saved }
        else if case .success(let validated) = draft.validated() { configuration = validated }
        else { lastFault = .invalidConfiguration; return nil }
        let request = ARLNASActionRequest(action: action, configuration: configuration,
            expectedSnapshotRevision: snapshot.revision,
            expectedConfigurationGeneration: snapshot.currentConfigurationGeneration,
            readScope: snapshot.configuration == configuration ? snapshot.readScope : nil)
        invalidateDirectories()
        let intent = ARLNASManualIntent(request: request)
        var stoppedSaveRequest: ARLNASActionRequest?
        if action == .stop {
            // Only this model's one pending Save with this exact predecessor
            // may explain a different current configuration in the Stop reply.
            let saves = pendingActions.filter { id, pending in
                !cancelledIntentIDs.contains(id) && pending.request.action == .saveConfiguration
                    && pending.request.expectedSnapshotRevision == request.expectedSnapshotRevision
                    && pending.request.expectedConfigurationGeneration == request.expectedConfigurationGeneration
            }
            if saves.count == 1 { stoppedSaveRequest = saves.first?.value.request }
            // The button cancels its existing Task before entering this method.
            // Also discard any late reply from the superseded host operation.
            cancelledIntentIDs.formUnion(pendingActions.keys)
            stopIntentID = intent.id
        }
        pendingActions[intent.id] = PendingAction(request: request, callerPins: snapshot.observedCallerPins,
                                                  stoppedSaveRequest: stoppedSaveRequest)
        isPerforming = true
        cleanupPending = stopIntentID != nil || !cancelledIntentIDs.isEmpty
        lastFault = nil
        return intent
    }

    public func performAfterClick(_ manualIntent: ARLNASManualIntent) async {
        guard let pending = pendingActions[manualIntent.id], pending.request == manualIntent.request
        else { lastFault = .manualIntentRequired; return }
        defer { finishManualAction(manualIntent.id) }
        guard !manualIntent.hasExpired else { lastFault = .manualIntentExpired; return }
        let request = manualIntent.request
        // Credential material cannot be routed to the generic backend.
        guard request.action != .saveCredential else { lastFault = .credentialEntryUnavailable; return }
        guard !cancelledIntentIDs.contains(manualIntent.id), !Task.isCancelled else { return }
        let reply = await backend.perform(request, manualIntent: manualIntent)
        guard !cancelledIntentIDs.contains(manualIntent.id), !Task.isCancelled else { return }
        accept(reply, request: request, expectedCaller: pending.callerPins,
               stoppedSaveRequest: pending.stoppedSaveRequest)
    }

    public func saveCredentialAfterClick(_ input: ARLNASCredentialInput,
                                        manualIntent: ARLNASManualIntent) async {
        defer { input.clear() }
        guard let pending = pendingActions[manualIntent.id], pending.request == manualIntent.request
        else { lastFault = .manualIntentRequired; return }
        defer { finishManualAction(manualIntent.id) }
        guard !manualIntent.hasExpired else { lastFault = .manualIntentExpired; return }
        let request = manualIntent.request
        guard request.action == .saveCredential else { lastFault = .manualIntentRequired; return }
        guard let credentialConsumer, input.hasMaterial else {
            lastFault = .credentialEntryUnavailable
            return
        }
        guard !cancelledIntentIDs.contains(manualIntent.id), !Task.isCancelled else { return }
        let reply = await credentialConsumer.save(input, request: request, manualIntent: manualIntent)
        guard !cancelledIntentIDs.contains(manualIntent.id), !Task.isCancelled else { return }
        accept(reply, request: request, expectedCaller: pending.callerPins,
               stoppedSaveRequest: pending.stoppedSaveRequest)
    }

    private func finishManualAction(_ id: UUID) {
        pendingActions.removeValue(forKey: id)
        cancelledIntentIDs.remove(id)
        if stopIntentID == id { stopIntentID = nil }
        isPerforming = !pendingActions.isEmpty
        cleanupPending = stopIntentID != nil || !cancelledIntentIDs.isEmpty
    }

    private func accept(_ reply: ARLNASActionReply, request: ARLNASActionRequest,
                        expectedCaller: ARLNASObservedCallerPins?, stoppedSaveRequest: ARLNASActionRequest?) {
        guard reply.request == request, reply.snapshot.revision >= request.expectedSnapshotRevision
        else { lastFault = .bindingMismatch; return }
        if request.action == .stop {
            guard snapshot.configuration == request.configuration else {
                lastFault = .configurationChanged
                return
            }
        } else {
            guard case .success(let current) = draft.validated(), current == request.configuration
            else { lastFault = .configurationChanged; return }
        }

        if reply.outcome == .applied {
            let stopAfterSave = request.action == .stop && stoppedSaveRequest?.action == .saveConfiguration
                && stoppedSaveRequest?.expectedSnapshotRevision == request.expectedSnapshotRevision
                && stoppedSaveRequest?.expectedConfigurationGeneration == request.expectedConfigurationGeneration
            let exactConfiguration = reply.snapshot.configuration == request.configuration
                || (stopAfterSave && reply.snapshot.configuration == stoppedSaveRequest?.configuration)
            guard exactConfiguration,
                  reply.snapshot.configurationSaved == .verified
            else { lastFault = .bindingMismatch; return }
            switch request.action {
            case .saveConfiguration: break
            case .saveCredential:
                guard reply.snapshot.credentialReferenceSaved == .verified,
                      reply.snapshot.readScope != nil
                else { lastFault = .bindingMismatch; return }
            case .testConnection, .reconnect:
                let native = backend.generationSemantics == .configurationChanges
                let target = request.expectedConfigurationGeneration.addingReportingOverflow(native ? 0 : 1)
                let nextRevision = request.expectedSnapshotRevision.addingReportingOverflow(1)
                guard !native || (!nextRevision.overflow && reply.snapshot.revision == nextRevision.partialValue
                    && reply.snapshot.readScope == request.readScope) else { lastFault = .bindingMismatch; return }
                guard !target.overflow,
                      reply.snapshot.currentConfigurationGeneration == target.partialValue,
                      reply.snapshot.readScope?.configGeneration == target.partialValue,
                      sameScopeIdentity(reply.snapshot.readScope, request.readScope),
                      reply.snapshot.observedCallerPins == expectedCaller,
                      reply.snapshot.connectionEpoch != nil, reply.snapshot.connected == .verified
                else { lastFault = .bindingMismatch; return }
            case .testRead:
                guard reply.snapshot.readScope == request.readScope,
                      reply.snapshot.currentConfigurationGeneration == request.expectedConfigurationGeneration,
                      reply.snapshot.observedCallerPins == expectedCaller,
                      reply.snapshot.connectionEpoch == snapshot.connectionEpoch,
                      reply.snapshot.connectionEpoch != nil, reply.snapshot.readable == .verified
                else { lastFault = .bindingMismatch; return }
            case .testWrite:
                lastFault = .writeUnsupported
                return
            case .stop:
                let native = backend.generationSemantics == .configurationChanges
                let ordinary = request.expectedConfigurationGeneration.addingReportingOverflow(native ? 0 : 1)
                let saved = request.expectedConfigurationGeneration.addingReportingOverflow(2)
                let revision = request.expectedSnapshotRevision.addingReportingOverflow(1)
                let exactGeneration = (!ordinary.overflow
                    && reply.snapshot.currentConfigurationGeneration == ordinary.partialValue
                    && reply.snapshot.configuration == request.configuration)
                    || (!native && stopAfterSave && !saved.overflow
                        && reply.snapshot.currentConfigurationGeneration == saved.partialValue
                        && reply.snapshot.configuration == stoppedSaveRequest?.configuration)
                guard (!native || reply.snapshot.observedCallerPins == expectedCaller), exactGeneration, !revision.overflow,
                      reply.snapshot.revision == revision.partialValue,
                      reply.snapshot.connectionEpoch == nil,
                      reply.snapshot.connected != .verified, reply.snapshot.readable != .verified,
                      reply.snapshot.readScope == request.readScope, request.readScope != nil
                else { lastFault = .bindingMismatch; return }
            }
        }
        snapshot = reply.snapshot
        hasUncertainWrite = hasUncertainWrite || reply.outcome == .uncertainWrite || snapshot.writable == .uncertainWrite
        lastFault = reply.outcome.fault
        // No automatic retry, connection action, credential use or readiness toggle.
    }

    private func sameScopeIdentity(_ lhs: ARLNASReadScope?, _ rhs: ARLNASReadScope?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.service == rhs.service && lhs.sourceRef == rhs.sourceRef
            && lhs.credentialRef == rhs.credentialRef && lhs.credentialGeneration == rhs.credentialGeneration
            && lhs.configFingerprint == rhs.configFingerprint && lhs.rootDescriptorDigest == rhs.rootDescriptorDigest
    }
}

@available(macOS 13.0, *)
@MainActor
public struct ARLNASSetupPanel: View {
    @StateObject private var model: ARLNASSetupModel
    @StateObject private var discovery = NASDiscoveryModel()
    @State private var account = ""
    @State private var secret = ""
    @State private var showsAdvanced = false
    @State private var uploadTestDirectory = ""
    @State private var actionTask: Task<Void, Never>?
    @State private var stopTask: Task<Void, Never>?

    public init(model: ARLNASSetupModel) { _model = StateObject(wrappedValue: model) }
    public init() { self.init(model: ARLNASSetupModel()) }

    public var body: some View {
        Form {
            Section {
                Text("网络硬盘").font(.title2).fontWeight(.semibold)
                Text(providerMessage).foregroundStyle(.secondary)
                if let fault = model.lastFault {
                    Label(fault.message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(fault.message)
                }
            }
            NASDiscoverySection(discovery: discovery, setup: model)
            if let owner=model.serverSetupOwner {
                NASServerSetupSections(owner:owner,setup:model)
            } else {
                configurationSection
                credentialSection
                statusSection
                directorySection
                uploadTestSection
                advancedSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, idealWidth: 680, minHeight: 700)
        .onAppear { model.refreshCachedStatus() }
        .task {
            while !Task.isCancelled {
                model.refreshCachedStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: model.draft) { _ in clearCredentialFields(); model.invalidateDirectories() }
        .onDisappear { clearCredentialFields(); discovery.cancel(); actionTask?.cancel(); model.invalidateDirectories() }
    }

    private var configurationSection: some View {
        Section("连接范围") {
            TextField("设备地址", text: $model.draft.address).help("主机名、IPv4 或 smb://主机名；共享名在下面单独填写")
            if let address = try? NASAddressInput(model.draft.address, port: model.draft.port) {
                Text("连接到 " + address.host + ":" + String(address.port)).font(.caption).foregroundStyle(.secondary)
            }
            Picker("连接方式", selection: $model.draft.transport) {
                ForEach(ARLNASTransport.allCases, id: \.self) { transport in
                    Text(transport == .sftp ? transport.title + " · " + "此界面不支持SFTP" : transport.title).tag(transport)
                }
            }
            TextField("共享目录", text: $model.draft.share)
            if !model.shareSuggestions.isEmpty {
                Menu("选择共享") {
                    ForEach(model.shareSuggestions, id: \.self) { share in
                        Button(share) { model.draft.share = share; model.draft.root = "" }
                    }
                }
            }

            TextField("目录范围", text: $model.draft.root).help("共享目录内允许读取的起始目录")
            Picker("使用范围", selection: $model.draft.applicationScope) {
                Text("只读访问").tag(ARLNASApplicationScope.readOnly)
                Text("申请读写").tag(ARLNASApplicationScope.readWriteRequested)
            }

            manualButton(.saveConfiguration)
        }
        .disabled(model.isPerforming)
    }

    private var directorySection: some View {
        Section("浏览目录") {
            Button("查看目录") {
                actionTask = Task { await model.browseDirectoriesAfterClick() }
            }.disabled(!model.canBrowseDirectories)
            if let page = model.directoryPage {
                Text(page.path.isEmpty ? "当前已保存范围" : page.path).textSelection(.enabled)
                if !page.path.isEmpty {
                    Button("上一级") {
                        let parent = page.path.split(separator: "/").dropLast().joined(separator: "/")
                        actionTask = Task { await model.browseDirectoriesAfterClick(path: parent) }
                    }.disabled(!model.canBrowseDirectories)
                }
                ForEach(page.directories, id: \.self) { directory in
                    Button(directory.split(separator: "/").last.map(String.init) ?? directory) {
                        actionTask = Task { await model.browseDirectoriesAfterClick(path: directory) }
                    }.disabled(!model.canBrowseDirectories)
                }
                if let cursor = page.nextCursor {
                    Button("下一页") {
                        actionTask = Task { await model.browseDirectoriesAfterClick(path: page.path, cursor: cursor) }
                    }.disabled(!model.canBrowseDirectories)
                }
                Button("使用目录") { model.selectDirectoryAsRoot() }
                    .disabled(!model.canBrowseDirectories || page.path.isEmpty)
                Button("设为测试") { uploadTestDirectory = page.path }
                    .disabled(!model.canBrowseDirectories || page.path.isEmpty)

            }
            if let message = model.directoryMessage { Text(message).foregroundStyle(.secondary) }
        }
    }

    private var uploadTestSection: some View {
        Section("新建测试") {
            TextField("测试目录", text: $uploadTestDirectory)

            Button("创建测试") {
                actionTask = Task { await model.uploadTestAfterClick(directory: uploadTestDirectory) }
            }
            .disabled(!model.canTestNewFile || uploadTestDirectory.isEmpty)
            if let message = model.uploadMessage { Text(message).textSelection(.enabled) }
        }
    }

    private var credentialSection: some View {
        Section("登录信息") {
            TextField("账号", text: $account).privacySensitive()
                .accessibilityIdentifier("nas-account")
                .disabled(!model.canEditCredentialFields)
            SecureField("密码", text: $secret).privacySensitive()
                .accessibilityIdentifier("nas-password")
                .disabled(!model.canEditCredentialFields)

            if let guidance = model.credentialSaveGuidance {
                Text(guidance).font(.caption).foregroundStyle(.secondary)
            }
            Button("保存登录") { submitCredentialAfterClick() }
                .disabled(!model.admission(for: .saveCredential).isAllowed || account.isEmpty || secret.isEmpty)
                .help(model.admission(for: .saveCredential).fault?.message ?? ("本机保存" + "\n" + "通过本机程序保存登录信息"))

        }
    }

    private var statusSection: some View {
        Section("设置状态") {

            ForEach(ARLNASStatusField.allCases, id: \.self) { field in
                Text(field.displayExplanation).font(.caption).foregroundStyle(.secondary)
                LabeledContent(field.title) {
                    Text(model.fact(for: field).title)
                        .foregroundStyle(.secondary)
                        .help(model.fact(for: field).detail)
                }
            }
            HStack {
                manualButton(.testConnection)
                manualButton(.testRead)
                manualButton(.reconnect)
                manualButton(.stop)
            }
            Button("刷新状态") { model.refreshCachedStatus() }
                .disabled(model.isPerforming)
                .help(("只刷新已保存的状态" + "\n" + "只读取本机服务缓存，不连接、不调用登录信息，也不会弹出授权提示。"))

            if model.cleanupPending {
                ProgressView(("等待结束" + "\n" + "清理尚未完成，正在等待本机服务返回。")).controlSize(.small)
            } else if model.isPerforming {
                ProgressView(("处理中" + "\n" + "正在等待本机服务执行操作。")).controlSize(.small)
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("连接选项", isExpanded: $showsAdvanced) {
                TextField("连接端口", value: $model.draft.port, format: .number).help("填写SMB连接端口")
                LabeledContent("自动重试", value: "0；当前不支持").help("当前不支持；读取失败不会自动重试")
                Stepper("连接时限：\(model.draft.connectionTimeoutSeconds) 秒",
                        value: $model.draft.connectionTimeoutSeconds, in: 1...30).help("本次连接最多\(model.draft.connectionTimeoutSeconds)秒")
                LabeledContent("同时读取", value: "1").help("当前只允许依次读取，每次1项")

            }
        }
        .disabled(model.isPerforming)
    }

    private var providerMessage: String {
        switch model.snapshot.provider {
        case .unsupported:
            return "硬盘登录服务尚未接通"
        case .held:
            return "硬盘操作暂停，请核对状态。"
        case .available:
            return "保存设置后仍需连接与授权"
        }
    }

    private func manualButton(_ action: ARLNASManualAction) -> some View {
        Button(action.title) {
            if action == .stop { actionTask?.cancel() }
            guard let intent = model.beginManualActionAfterClick(action) else { return }
            let task = Task { await model.performAfterClick(intent) }
            if action == .stop { stopTask = task } else { actionTask = task }
        }
        .disabled(!model.admission(for: action).isAllowed)
        .help(model.admission(for: action).fault?.message ?? action.displayExplanation)
    }

    private func submitCredentialAfterClick() {
        guard let intent = model.beginManualActionAfterClick(.saveCredential) else { return }
        let input = ARLNASCredentialInput(username: account, password: secret)
        // Clear all view bindings before the Task can reach its first await.
        clearCredentialFields()
        actionTask = Task {
            defer { input.clear() }
            await model.saveCredentialAfterClick(input, manualIntent: intent)
        }
    }

    private func clearCredentialFields() {
        account.removeAll(keepingCapacity: false)
        secret.removeAll(keepingCapacity: false)
    }
}

private extension ARLNASTransport {
    var title: String {
        switch self {
        case .smb: return "SMB"
        case .sftp: return "SFTP"
        }
    }
}

private extension ARLNASManualAction {
    var displayExplanation: String {
        switch self {
        case .saveCredential: "由本机服务保存硬盘登录信息"
        case .testWrite: "当前读取服务不支持此操作"
        case .reconnect: "手动重新连接网络硬盘"
        default: title
        }
    }
    var title: String {
        switch self {
        case .saveConfiguration: return "保存设置"
        case .saveCredential: return "保存登录"
        case .testConnection: return "测试连接"
        case .testRead: return "测试读取"
        case .testWrite: return "测试写入"
        case .reconnect: return "重新连接"
        case .stop: return "停止操作"
        }
    }
}

private extension ARLNASStatusField {
    var displayExplanation: String {
        switch self {
        case .configurationSaved: "是否已保存当前这份设置"
        case .credentialReferenceSaved: "只表示已有记录，登录仍待核验"
        case .credentialAvailable: "当前设置对应的登录信息是否可用"
        default: ""
        }
    }
    var title: String {
        switch self {
        case .configurationSaved: return "保存状态"
        case .credentialReferenceSaved: return "登录记录"
        case .credentialAvailable: return "登录状态"
        case .connected: return "连接状态"
        case .readable: return "读取状态"
        case .writable: return "写入状态"
        }
    }
}

private extension ARLNASFact {
    var title: String {
        switch self {
        case .unknown: return ("未核验" + "\n" + "尚未核验本项。")
        case .verified: return "已核验"
        case .held: return "已暂停"
        case .failed: return "失败"
        case .unsupported: return "不支持"
        case .uncertainWrite: return ("结果未知" + "\n" + "本项结果未知。")
        }
    }

    var detail: String {
        switch self {
        case .unknown: return ("当前设置的本项尚未核验" + "\n" + "尚无记录证明当前已保存设置对应的这一项可用。")
        case .verified: return ("只核验当前设置与版本" + "\n" + "本机服务已核对当前这份已保存设置及其版本；记录只适用于该设置和版本。")
        case .held(let fault), .failed(let fault), .unsupported(let fault): return fault.message
        case .uncertainWrite: return ARLNASFault.writeOutcomeUncertain.message
        }
    }
}

private extension ARLNASFault {
    var message: String {
        switch self {
        case .hostNotConfigured: return ("保存服务未安装" + "\n" + "尚未安装负责保存设置的本机服务。")
        case .nativeNASPurposeUnavailable: return ("硬盘登录未接入" + "\n" + "本机登录模块尚未支持网络硬盘登录。")
        case .nativeResolverUnavailable: return ("登录服务不可用" + "\n" + "网络硬盘的本机登录服务不可用。")
        case .invalidConfiguration: return ("请填写地址与目录" + "\n" + "请填写SMB设备地址、端口、共享目录及目录内的起始位置。地址不能夹带登录信息，起始位置不能越出共享目录。")
        case .configurationNotSaved: return ("请先保存设置" + "\n" + "调用登录信息或测试前，请先保存当前这份设置。")
        case .configurationChanged: return ("设置已变，请重新检查" + "\n" + "设置已改变，之前的核对记录不适用于当前设置。")
        case .credentialNotSaved: return ("请核对登录与操作授权" + "\n" + "登录信息须对应当前设置。\n本次操作还需本机服务授权。")
        case .credentialEntryUnavailable: return ("登录服务未安装" + "\n" + "安全填写登录信息需要先安装本机服务。")
        case .bindingMismatch: return ("记录与设置不符" + "\n" + "本机服务返回的核对记录属于另一份设置，不适用于当前设置。")
        case .staleGeneration: return ("设置版本已变" + "\n" + "已保存的设置版本发生改变。")
        case .callerRejected: return ("应用身份未通过检查" + "\n" + "本机服务无法确认发起操作的程序与登记程序一致。")
        case .manualIntentRequired: return ("请重新点击操作" + "\n" + "请重新手动发起本次操作。")
        case .operationInProgress: return ("已有操作正在进行" + "\n" + "本机服务正在执行另一项操作。")
        case .authenticationRequired: return ("请重新授权本次操作" + "\n" + "验证登录前，需要重新手动取得本机服务的本次操作许可。")
        case .userCancelled: return ("已取消" + "\n" + "本次操作已取消。")
        case .connectionFailed: return "连接失败"
        case .readDenied: return ("读取被拒" + "\n" + "读取访问被拒绝。")
        case .writeUnsupported: return ("不支持日常写入" + "\n" + "当前读取服务不支持写入。")
        case .writeDenied: return ("写入被拒" + "\n" + "写入访问被拒绝。")
        case .writeOutcomeUncertain: return ("写入未知，请先核对" + "\n" + "写入结果未知；再次写入前必须先核对实际结果。")
        case .disabled: return ("硬盘访问已停用" + "\n" + "本机服务已停用网络硬盘访问。")
        case .sourceChanged: return ("设置已变，请重新授权" + "\n" + "来源设置已改变；需要重新取得本机服务的本次操作许可。")
        case .referenceMismatch: return ("登录记录与设置不符" + "\n" + "登录记录与已保存的设置不一致。")
        case .revoked: return ("本次授权已撤回" + "\n" + "本机服务已撤回本次操作许可。")
        case .expired: return ("本次授权已过期" + "\n" + "本机服务授予的本次操作许可已过期。")
        case .budgetExhausted: return "连接次数已用完"
        case .ticketInvalid: return ("本次操作授权无效" + "\n" + "本机服务内部的本次操作凭证无效。")
        case .providerInvalid: return ("返回内容未通过检查" + "\n" + "本机服务返回的内容未满足接入要求。")
        case .credentialsUnavailable: return ("当前登录信息不可用" + "\n" + "当前这份设置对应的登录信息不可用。")
        case .credentialInvalid: return ("登录信息无效" + "\n" + "本机服务中的登录信息无效。")
        case .authenticationFailed: return "登录失败"
        case .accessDenied: return ("访问被拒" + "\n" + "网络硬盘访问被拒绝。")
        case .hostKeyMismatch: return ("设备身份与设置不符" + "\n" + "服务器身份与已批准的设置不一致。")
        case .transportTimeout: return "传输超时"
        case .transportFailed: return "传输失败"
        case .protocolUnsupported: return ("仅支持 SMB 连接" + "\n" + "此界面支持SMB。SFTP需要专门的本机设置流程，并审核服务器密钥与不可越出的目录范围。")
        case .manualIntentExpired: return ("操作已过期，请重新点击" + "\n" + "本次手动操作已过期；请重新点击发起新请求。")
        }
    }
}
