import Foundation

/// App-local entry point. The UI receives bounded public read DTOs, never a secret-reading API, raw response or native handle.
public enum CredentialOwnerReadiness: Sendable { case ready, busy, cleanupUnproven }

public actor CredentialOnboarding {
    public nonisolated let usesSeparateTeamEntry: Bool
    public nonisolated let nas: NASCredentialService
    private let repository: any CredentialRepository
    private let validator: any CredentialValidator
    private let legacyTravel: (any LegacyTravelSource)?
    private let music: (any MusicTransport)?
    private let travelReads: (any TravelReadTransport)?
    private let musicReads: (any MusicReadTransport)?
    private let musicWrites: (any MusicWriteTransport)?
    private let musicCovers: (any MusicPlaylistCoverTransport)?
    private let coverJournal: (any MusicPlaylistCoverJournal)?
    private let coverImages: any MusicPlaylistCoverImageLoader
    private let writeJournal: (any MusicWriteJournal)?
    private let businessJournal: MusicBusinessJournal?
    private var musicProcessBarrier: (any MusicProcessBarrier)?
    private var musicCleanupPending = false
    private var musicPendingCleanupGeneration: UUID?
    private var testing: Set<CredentialPurpose> = []
    private var aggregateCache = MusicAggregateSearchCache()
    private var aggregateFlight: (id: UUID, reference: CredentialReference, task: Task<MusicAggregateSearchResult, Error>)?
    private var aggregateWaiters = 0
    private let musicSearchNow: @Sendable () -> TimeInterval
    init(repository: any CredentialRepository, validator: any CredentialValidator, music: (any MusicTransport)? = nil,
         travelReads: (any TravelReadTransport)? = nil, musicReads: (any MusicReadTransport)? = nil, musicWrites: (any MusicWriteTransport)? = nil,
         writeJournal: (any MusicWriteJournal)? = nil, usesSeparateTeamEntry: Bool = false, legacyTravel: (any LegacyTravelSource)? = nil,
         nasRuntime: (any NASConnectionRuntime)? = nil, nasEnabled: Bool = false,
          musicSearchNow: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
          businessJournal: MusicBusinessJournal? = nil,
          musicCovers: (any MusicPlaylistCoverTransport)? = nil, coverJournal: (any MusicPlaylistCoverJournal)? = nil,
          coverImages: any MusicPlaylistCoverImageLoader = MusicPlaylistCoverHTTPSImageLoader()) {
        self.musicCovers = musicCovers ?? (music as? any MusicPlaylistCoverTransport)
        self.coverJournal = coverJournal; self.coverImages = coverImages
        self.businessJournal = businessJournal
        self.musicSearchNow = musicSearchNow
        self.usesSeparateTeamEntry = usesSeparateTeamEntry
        self.nas = NASCredentialService(repository: repository, runtime: nasRuntime, enabled: nasEnabled)
        self.repository = repository; self.validator = validator; self.music = music; self.legacyTravel = legacyTravel
        self.travelReads = travelReads; self.musicReads = musicReads ?? (music as? any MusicReadTransport)
        self.musicWrites = musicWrites ?? (music as? any MusicWriteTransport); self.writeJournal = writeJournal
    }
    public static func disabled() -> CredentialOnboarding {
        let gate = DisabledDeploymentGate()
        return .init(repository: KeychainRepository(gate: gate, calls: SystemSecurityItemCalls(), accessGroup: "disabled-no-access-group"), validator: VendorValidator(transport: BoundedHTTPS(gate: gate), flyAIProfile: nil))
    }
    /// Does not launch or call Security at construction. Final policy approval and explicit UI actions precede native effects.
    public static func approvedMacOS(deployment: CredentialDeployment, flyAIProfile: FlyAIGatewayProfile? = nil,
                                     validationPurposes: Set<CredentialPurpose>) -> CredentialOnboarding {
        let gate = NativeDeploymentGate(deployment: deployment)
        return .init(repository: KeychainRepository(gate: gate, calls: SystemSecurityItemCalls(), accessGroup: deployment.applicationAccessGroup), validator: VendorValidator(transport: BoundedHTTPS(gate: gate), flyAIProfile: flyAIProfile, validationPurposes: validationPurposes),
                     travelReads: TravelReadClient(transport: BoundedHTTPS(gate: gate), flyAIProfile: flyAIProfile, allowedPurposes: validationPurposes))
    }
    /// Explicit local login-Keychain route. Construction has no native or file effects.
    /// Never imports the Data Protection alternative or any legacy credentials.
    public static func approvedLoginMacOS(deployment: LoginCredentialDeployment, flyAIProfile: FlyAIGatewayProfile? = nil,
                                          validationPurposes: Set<CredentialPurpose>) -> CredentialOnboarding {
        let gate = NativeLoginDeploymentGate(deployment: deployment)
        let receipts = FileLoginReceiptStore(directory: deployment.receiptDirectory)
        let repository = LoginKeychainRepository(gate: gate, calls: SystemLoginItemCalls(),
            environment: NativeLoginEnvironment(deployment: deployment), receipts: receipts, identity: deployment.stableIdentity,
            itemScope: deployment.itemScope)
        let businessJournal = MusicBusinessJournal(directory: deployment.receiptDirectory.appendingPathComponent("music-business-v1.noindex"))
        return .init(repository: repository, validator: VendorValidator(transport: BoundedHTTPS(gate: gate), flyAIProfile: flyAIProfile,
                                                                       validationPurposes: validationPurposes),
                     music: MusicRuntimeClient(gate: gate, bundleURL: deployment.bundleURL, businessJournal: businessJournal),
                     travelReads: TravelReadClient(transport: BoundedHTTPS(gate: gate), flyAIProfile: flyAIProfile, allowedPurposes: validationPurposes),
                     writeJournal: FileMusicWriteJournal(directory: deployment.receiptDirectory.appendingPathComponent("music-writes-v1")),
                     usesSeparateTeamEntry: deployment.identityRoute == .appleDevelopmentTeam,
                     legacyTravel: NativeLegacyTravelSource(gate: gate),
                      nasRuntime: NASRuntimeClient(gate: gate, repository: repository, bundleURL: deployment.bundleURL,
                        journalDirectory: deployment.receiptDirectory.appendingPathComponent("nas-upload-v1")),
                      nasEnabled: validationPurposes.contains(.nasSMB), businessJournal: businessJournal,
                      coverJournal: FileMusicPlaylistCoverJournal(directory: deployment.receiptDirectory.appendingPathComponent("music-covers-v1.noindex")))
    }
    public func recordMusicBoundary(tool: String, callID: UUID, argumentsJSON: Data, responseJSON: Data?, elapsedMS: Int) throws {
        guard tool.hasPrefix("mio_netease_") else { return }
        var args = try JSONSerialization.jsonObject(with: argumentsJSON)
        var loggedArguments = argumentsJSON
        if tool == "mio_netease_playlist_update_cover", var values = args as? [String: Any] {
            // Image URLs can carry third-party download authorization. Keep the
            // caller target and URL digest without persisting those credentials.
            if let text = values["image_url"] as? String {
                values["image_url_sha256"] = MusicRuntimeResources.hash(Data(text.utf8)); values.removeValue(forKey: "image_url")
            }
            loggedArguments = try JSONSerialization.data(withJSONObject: values); args = values
        }
        let requestID = (args as? [String: Any])?["request_id"] as? String ?? (args as? [String: Any])?["supersedes_request_id"] as? String
        var record: [String: Any] = ["event": responseJSON == nil ? "owner_request" : "owner_response",
                                    "tool": tool, "arguments_text": String(decoding: loggedArguments, as: UTF8.self), "elapsed_ms": elapsedMS,
                                    "mio_call_id": callID.uuidString]
        if let responseJSON { record["response_text"] = String(decoding: responseJSON, as: UTF8.self) }
        try? businessJournal?.append(record, requestID: requestID.flatMap(UUID.init(uuidString:)), callID: callID)
    }
    /// Local lifecycle observation only: no repository, credential, journal,
    /// Security or provider access. Retains the existing exact-generation barrier.
    public func ownerRecoveryReadiness() -> CredentialOwnerReadiness {
        refreshMusicCleanupBarrier()
        if musicCleanupPending || musicProcessBarrier.map({ !$0.cleanupStatus().provedIdle }) == true { return .cleanupUnproven }
        return testing.isEmpty ? .ready : .busy
    }
    public func snapshot(purpose: CredentialPurpose) -> CredentialSnapshot {
        do {
            guard let m = try repository.metadata(purpose) else { return .init(purpose: purpose, reference: nil, state: .notConfigured, lastTest: nil) }
            if purpose == .fliggyTravelReadOnly, m.state == .verified, m.lastTest?.evidence != .flyaiDifferentialReadOnlyResponse {
                return .init(purpose: purpose, reference: m.reference, state: .revalidationRequired, lastTest: m.lastTest)
            }
            if m.state == .verified, let checked = m.lastTest?.checkedAt {
                let age = Date().timeIntervalSince(checked)
                if age < 0 || age > 900 { return .init(purpose: purpose, reference: m.reference, state: .revalidationRequired, lastTest: m.lastTest) }
            }
            return m.snapshot
        }
        catch let e as CredentialError { return .init(purpose: purpose, reference: nil, state: e == .deploymentNotApproved || e == .identityMismatch ? .setupRequired : .localStorageUnavailable, lastTest: nil) }
        catch { return .init(purpose: purpose, reference: nil, state: .localStorageUnavailable, lastTest: nil) }
    }
    public func save(_ input: CredentialInput, purpose: CredentialPurpose) throws -> CredentialSnapshot {
        guard purpose != .nasSMB else { input.clear(); throw CredentialError.wrongPurpose }
        refreshMusicCleanupBarrier()
        guard !testing.contains(purpose) else { input.clear(); throw CredentialError.busy }
        return try repository.create(input, purpose: purpose).snapshot
    }
    public func update(_ reference: CredentialReference, input: CredentialInput) throws -> CredentialSnapshot {
        guard reference.purpose != .nasSMB else { input.clear(); throw CredentialError.wrongPurpose }
        refreshMusicCleanupBarrier()
        guard !testing.contains(reference.purpose) else { input.clear(); throw CredentialError.busy }
        if reference.purpose == .neteaseMusic {
            do { try rotateMusicEpoch(reference) } catch { input.clear(); throw error }
        }
        return try repository.replace(reference, input: input).snapshot
    }
    /// One explicit user action owns the purpose slot through durable save and
    /// bounded verification. Recovery never overwrites a previously created item.
    public func saveAndVerify(_ input: CredentialInput, purpose: CredentialPurpose,
                              replacing: CredentialReference? = nil) async throws -> CredentialSubmissionResult {
        guard purpose != .nasSMB else { input.clear(); throw CredentialError.wrongPurpose }
        guard purpose == .neteaseMusic else { return try await submitTravel(input, purpose: purpose, replacing: replacing) }
        let trace=MusicDiagnosticTrace()
        return try await MusicDiagnostics.$current.withValue(trace) {
            trace.record(.owner,.started)
            do { return try await saveAndVerifyTracked(input,purpose:purpose,replacing:replacing) }
            catch { trace.fail(error,phase:.owner);throw error }
        }
    }
    private func saveAndVerifyTracked(_ input:CredentialInput,purpose:CredentialPurpose,
                                     replacing:CredentialReference?) async throws -> CredentialSubmissionResult {
        defer { input.clear() }
        refreshMusicCleanupBarrier()
        guard input.purpose == purpose, replacing == nil || replacing?.purpose == purpose else { input.clear(); throw CredentialError.wrongPurpose }
        guard !testing.contains(purpose) else { input.clear(); throw CredentialError.busy }
        try Task.checkCancellation()
        testing.insert(purpose)
        defer {
            if purpose != .neteaseMusic || !musicCleanupPending { testing.remove(purpose) }
        }
        let creation: CredentialCreation
        if let replacing {
            if purpose == .neteaseMusic { try rotateMusicEpoch(replacing) }
            creation = .init(metadata: try repository.replace(replacing, input: input), recoveredExisting: false)
        } else { creation = try repository.createRecovering(input, purpose: purpose) }
        let reference = creation.metadata.reference
        if purpose == .neteaseMusic { MusicDiagnostics.current?.record(.owner,.succeeded) }
        do {
            try Task.checkCancellation()
            let checked: CredentialSnapshot
            if purpose == .neteaseMusic {
                guard let music, musicReads != nil else { throw CredentialError.deploymentNotApproved }
                try rotateMusicEpoch(reference)
                let lease = try repository.lease(reference)
                defer { lease.secret.clear() }
                musicProcessBarrier = music as? any MusicProcessBarrier
                let prepared = try await music.send(lease.secret, operation: .prepare, onLoginURL: { _ in })
                defer { prepared.credential.clear() }
                try Task.checkCancellation()
                guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
                do {
                    MusicDiagnostics.current?.record(.token_store,.started)
                    _ = try commitMusicLease(reference, input: prepared.credential, result: nil, expectedGeneration: lease.metadata.generation)
                    MusicDiagnostics.current?.record(.token_store,.succeeded)
                } catch { MusicDiagnostics.current?.fail(error,phase:.token_store);throw error }
                let result = try await writeReadStep(reference, request: .userPlaylists)
                guard let current = try repository.metadata(purpose), current.reference == reference else { throw CredentialError.staleReference }
                if result.state == .authorizedRead {
                    checked = try repository.record(reference, result: .init(.verified, evidence: .neteasePlaylistReadResponse),
                                                    expectedGeneration: current.generation).snapshot
                } else { checked = current.snapshot }
            } else {
                checked = try await validateVendorHeld(reference, deadline: .now.advanced(by: .seconds(10)))
            }
            return .init(snapshot: checked, recoveredExisting: creation.recoveredExisting, verificationFailure: nil)
        } catch {
            let cleanupProven = purpose != .neteaseMusic || finishMusicOperation(releaseSlot: false)
            let failure: String
            if !cleanupProven { failure = "连接进程仍在结束；清理完成前不能开始新操作。" }
            else if let storage = error as? CredentialStorageFailure { failure = storage.message }
            else if error is CancellationError { failure = "操作已取消，未自动重试。" }
            else if error as? CredentialError == .deploymentNotApproved || error as? CredentialError == .identityMismatch { failure = "应用接入或身份校验未通过。" }
            else if error is LoginACLFailure { failure = ("保存结果未确认，请先核对状态" + "\n" + "本地安全存储访问校验未通过；保存或更新结果未确认，未自动重试，未调整访问权限。") }
            else if let diagnostic=MusicDiagnostics.current?.lastFailure { failure=diagnostic.message }
            else { failure = "连接检查未完成，当前状态以本地回读为准。" }
            return .init(snapshot: snapshot(purpose: purpose), recoveredExisting: creation.recoveredExisting, verificationFailure: failure)
        }
    }
    public func legacyTravelStatus(purpose: CredentialPurpose) -> LegacyTravelStatus {
        guard purpose.isTravel, let legacyTravel else { return .unavailable }
        do { return try legacyTravel.inspect(purpose) } catch { return .unavailable }
    }
    /// Invoked only by an explicit ARL migration button. The legacy files are
    /// read-only, retained in place, and never exposed over Mio/owner IPC.
    public func migrateLegacyTravel(purpose: CredentialPurpose) async throws -> CredentialSubmissionResult {
        guard purpose.isTravel, let legacyTravel else { throw CredentialError.deploymentNotApproved }
        guard !testing.contains(purpose) else { throw CredentialError.busy }
        testing.insert(purpose); defer { testing.remove(purpose) }
        try Task.checkCancellation()
        let existing = try repository.recoverTravelMetadata(purpose)
        guard existing == nil else { throw CredentialError.alreadyConfigured }
        try Task.checkCancellation()
        let source: LegacyTravelLease
        do { source = try legacyTravel.read(purpose) }
        catch { TravelCredentialDiagnostics.record(purpose, phase: .source, state: .unconfirmed); throw error }
        defer { source.secret.clear() }
        TravelCredentialDiagnostics.record(purpose, phase: .source, state: .succeeded)
        return try await validateAndInstallTravel(source.secret, purpose: purpose, expected: nil, source: source)
    }
    /// A failed or interrupted persistence operation is reconciled separately;
    /// this action never submits a source or candidate a second time.
    public func recoverTravelSave(purpose: CredentialPurpose) throws -> CredentialSnapshot {
        guard purpose.isTravel else { throw CredentialError.wrongPurpose }
        guard !testing.contains(purpose) else { throw CredentialError.busy }
        _ = try repository.recoverTravelMetadata(purpose)
        TravelCredentialDiagnostics.record(purpose, phase: .recovery, state: .succeeded)
        return snapshot(purpose: purpose)
    }
    private func submitTravel(_ input: CredentialInput, purpose: CredentialPurpose, replacing: CredentialReference?) async throws -> CredentialSubmissionResult {
        defer { input.clear() }
        guard purpose.isTravel, input.purpose == purpose, replacing == nil || replacing?.purpose == purpose else { throw CredentialError.wrongPurpose }
        guard !testing.contains(purpose) else { throw CredentialError.busy }
        testing.insert(purpose); defer { testing.remove(purpose) }
        try Task.checkCancellation()
        let expected = try repository.recoverTravelMetadata(purpose)
        if let replacing {
            guard expected?.reference == replacing else { throw CredentialError.staleReference }
        } else if expected != nil { throw CredentialError.alreadyConfigured }
        return try await validateAndInstallTravel(input, purpose: purpose, expected: expected, source: nil)
    }
    private func validateAndInstallTravel(_ input: CredentialInput, purpose: CredentialPurpose, expected: StoredMetadata?, source: LegacyTravelLease?) async throws -> CredentialSubmissionResult {
        defer { input.clear() }
        // Validator clears its argument. Keep the candidate in its private lease
        // until the successful validation can be committed atomically.
        let probe = try CredentialInput(purpose: purpose, data: input.copyBytes(for: purpose))
        let result = await validator.validate(probe, purpose: purpose, deadline: .now.advanced(by: .seconds(10)))
        probe.clear()
        TravelCredentialDiagnostics.record(purpose, phase: .validation, state: .tested, result: result)
        try Task.checkCancellation()
        guard TravelCredentialEvidence.accepts(result, purpose: purpose) else {
            return .init(snapshot: snapshot(purpose: purpose), recoveredExisting: false,
                         verificationFailure: result.state == .verified ? "返回结果未满足此用途的验证证据。" : "连接验证未通过：" + result.state.title + (result.diagnostic.map { "；" + $0.title } ?? ""),
                         saved: false, candidateTest: result)
        }
        do {
            try source?.verifyUnchanged()
            try Task.checkCancellation()
            let metadata = try repository.installVerifiedTravel(input, result: result, expected: expected)
            TravelCredentialDiagnostics.record(purpose, phase: .commit, state: .succeeded)
            return .init(snapshot: metadata.snapshot, recoveredExisting: false, verificationFailure: nil, candidateTest: result)
        } catch {
            TravelCredentialDiagnostics.record(purpose, phase: .commit, state: .unconfirmed)
            throw error // No blind replay, ACL repair, legacy cleanup or fallback.
        }
    }
    public func testConnection(_ reference: CredentialReference) async throws -> CredentialSnapshot {
        guard reference.purpose != .nasSMB else { throw CredentialError.wrongPurpose }
        if reference.purpose == .neteaseMusic { return try await performMusic(reference, operation: .status) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        guard !testing.contains(reference.purpose) else { throw CredentialError.busy }
        testing.insert(reference.purpose); defer { testing.remove(reference.purpose) }
        return try await validateVendorHeld(reference, deadline: deadline)
    }
    private func validateVendorHeld(_ reference: CredentialReference, deadline: ContinuousClock.Instant) async throws -> CredentialSnapshot {
        let lease = try repository.lease(reference)
        defer { lease.secret.clear() }
        let validator = self.validator
        let result = await withTaskGroup(of: ConnectionTestResult.self) { group in
            group.addTask { await validator.validate(lease.secret, purpose: reference.purpose, deadline: deadline) }
            group.addTask {
                do { try await Task.sleep(until: deadline, clock: .continuous); return .init(.timedOut) }
                catch { return .init(.cancelled) }
            }
            let first = await group.next() ?? .init(.cancelled)
            group.cancelAll(); return first
        }
        try Task.checkCancellation()
        return try repository.record(reference, result: result, expectedGeneration: lease.metadata.generation).snapshot
    }
    public func performMusic(_ reference: CredentialReference, operation: MusicOperation,
                             onLoginURL: @escaping @Sendable (URL) -> Void = { _ in }) async throws -> CredentialSnapshot {
        let trace=MusicDiagnosticTrace()
        return try await MusicDiagnostics.$current.withValue(trace) {
            trace.record(.owner,.started)
            do { return try await performMusicTracked(reference,operation:operation,onLoginURL:onLoginURL) }
            catch {
                if trace.lastFailure==nil { trace.fail(error,phase:.owner) }
                throw error
            }
        }
    }
    private func performMusicTracked(_ reference:CredentialReference,operation:MusicOperation,
                                    onLoginURL:@escaping @Sendable (URL)->Void) async throws -> CredentialSnapshot {
        refreshMusicCleanupBarrier()
        guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
        guard !testing.contains(reference.purpose) else { throw CredentialError.busy }
        guard let music else { throw CredentialError.deploymentNotApproved }
        try Task.checkCancellation()
        musicProcessBarrier = music as? any MusicProcessBarrier
        testing.insert(reference.purpose)
        do {
            let lease = try repository.lease(reference)
            MusicDiagnostics.current?.record(.owner,.succeeded)
            defer { lease.secret.clear() }
            if operation == .login || operation == .prepare { try rotateMusicEpoch(reference) }
            let reply = try await music.send(lease.secret, operation: operation, onLoginURL: onLoginURL)
            defer { reply.credential.clear() }
            try Task.checkCancellation()
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            let result: ConnectionTestResult? = reply.state == .savedUnverified ? nil : .init(reply.state)
            let snapshot:CredentialSnapshot
            do {
                MusicDiagnostics.current?.record(.token_store,.started)
                snapshot=try commitMusicLease(reference,input:reply.credential,result:result,expectedGeneration:lease.metadata.generation).snapshot
                MusicDiagnostics.current?.record(.token_store,.succeeded)
            } catch {
                MusicDiagnostics.current?.fail(error,phase:.token_store)
                if let detail=MusicDiagnostics.current?.lastFailure { throw MusicDiagnosticFailure(diagnostic:detail) }
                throw error
            }
            if reply.state == .credentialUnconfirmed,let detail=MusicDiagnostics.current?.lastFailure {
                throw MusicDiagnosticFailure(diagnostic:detail)
            }
            return snapshot
        } catch {
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            throw error
        }
    }
    /// Uses the same purpose slot, owner gate and generation as save/update/testConnection.
    /// A read result is not credential-validation evidence and does not rewrite test metadata.
    public func consumeRead(_ reference: CredentialReference, request: TravelReadRequest) async throws -> TravelReadResult {
        guard reference.purpose == request.purpose else { throw CredentialError.wrongPurpose }
        guard !testing.contains(reference.purpose) else { throw CredentialError.busy }
        guard let travelReads else { throw CredentialError.deploymentNotApproved }
        try Task.checkCancellation()
        testing.insert(reference.purpose); defer { testing.remove(reference.purpose) }
        let lease = try repository.lease(reference)
        defer { lease.secret.clear() }
        let result = await TravelReadAuthorization.$generation.withValue(lease.metadata.generation) {
            await travelReads.sendRead(lease.secret, request: request)
        }
        try Task.checkCancellation()
        guard let current = try repository.metadata(reference.purpose), current.reference == reference,
              current.generation == lease.metadata.generation else { throw CredentialError.staleReference }
        return result
    }
    /// The official music read may refresh or clear its local session. Commit that envelope by generation before returning.
    public func consumeRead(_ reference: CredentialReference, request: MusicReadRequest) async throws -> MusicReadResult {
        try request.validate()
        refreshMusicCleanupBarrier()
        guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
        guard !testing.contains(reference.purpose) else { throw CredentialError.busy }
        guard let musicReads else { throw CredentialError.deploymentNotApproved }
        try Task.checkCancellation()
        musicProcessBarrier = musicReads as? any MusicProcessBarrier
        testing.insert(reference.purpose)
        do {
            let lease = try repository.lease(reference)
            defer { lease.secret.clear() }
            let reply = try await musicReads.sendRead(lease.secret, request: request)
            defer { reply.credential.clear() }
            try Task.checkCancellation()
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            _ = try commitMusicLease(reference, input: reply.credential,
                result: .init(reply.result.connectionState), expectedGeneration: lease.metadata.generation)
            return reply.result
        } catch {
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            throw error
        }
    }

    /// Concurrent callers share the active scan, then query the same account index.
    /// The single owner slot and each caller's existing 15-second budget remain bounded.
    public func aggregateMusicSearch(_ reference: CredentialReference, query: MusicAggregateQuery) async throws -> MusicAggregateSearchResult {
        guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
        try Task.checkCancellation()
        let workEnd = ProcessInfo.processInfo.systemUptime + 15
        while let flight = aggregateFlight {
            guard flight.reference == reference, aggregateWaiters < 8 else { throw CredentialError.busy }
            try await waitForAggregateFlight(flight.id, until: workEnd)
        }
        refreshMusicCleanupBarrier()
        guard !testing.contains(reference.purpose) else { throw CredentialError.busy }
        guard let musicReads else { throw CredentialError.deploymentNotApproved }
        testing.insert(reference.purpose)
        let id = UUID()
        let task = Task { try await self.runAggregateMusicSearch(reference, query: query, workEnd: workEnd, transport: musicReads, flightID: id) }
        aggregateFlight = (id, reference, task)
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        return result
    }
    private func aggregateFlightIsActive(_ id: UUID) -> Bool { aggregateFlight?.id == id }
    private func waitForAggregateFlight(_ id: UUID, until deadline: TimeInterval) async throws {
        aggregateWaiters += 1
        defer { aggregateWaiters -= 1 }
        try await MusicSearchReadDeadline.waitForCompletion(until: deadline) {
            await self.aggregateFlightIsActive(id)
        }
    }
    private func runAggregateMusicSearch(_ reference: CredentialReference, query: MusicAggregateQuery,
                                         workEnd: TimeInterval, transport: any MusicReadTransport, flightID: UUID) async throws -> MusicAggregateSearchResult {
        defer { if aggregateFlight?.id == flightID { aggregateFlight = nil } }
        do {
            try Task.checkCancellation()
            let authorization = try repository.lease(reference)
            // Authorization lease also gates cache-only replies. No secret enters the cache.
            authorization.secret.clear()
            var generation = authorization.metadata.generation
            aggregateCache.bind(reference, generation: generation, now: musicSearchNow())
            var progress = try aggregateCache.begin(query, now: musicSearchNow())
            var publicResult: MusicReadResult?, cloudResult: MusicReadResult?
            var publicTimedOut = false, cloudTimedOut = false, publicAttempted = false, cloudAttempts = 0
            var session: MusicReadSession = .unconfirmed
            if progress.publicPending.isEmpty, let offset = progress.publicNext,
               ProcessInfo.processInfo.systemUptime < workEnd - 0.25 {
                publicAttempted = true
                do {
                    let (reply, committed) = try await aggregateReadStep(reference,
                        generation: generation, request: .search(keyword: query.keyword, offset: offset),
                        deadline: min(workEnd, ProcessInfo.processInfo.systemUptime + 7), transport: transport)
                    generation = committed.generation
                    publicResult = reply; session = reply.session
                    if reply.state == .authorizedRead, let payload = reply.payload, let page = payload.searchPage {
                        progress.publicStarted = true; progress.publicPage = page
                        progress.publicPending = payload.songs ?? []; progress.publicNext = page.nextOffset
                        progress.publicScanned = page.offset + progress.publicPending.count
                        progress.publicEnded = payload.complete || (page.total != nil && page.nextOffset == nil && page.offset + progress.publicPending.count == page.total)
                    }
                } catch TransportFailure.timeout { publicTimedOut = true }
                  catch TransportFailure.network { publicTimedOut = true }
            }
            try Task.checkCancellation()
            if aggregateCache.shouldRefresh(for: query, now: musicSearchNow()), ProcessInfo.processInfo.systemUptime < workEnd - 0.25 {
                aggregateCache.startCloudRefresh(now: musicSearchNow())
                while aggregateCache.wantsCloudPage &&
                      ProcessInfo.processInfo.systemUptime < workEnd - 0.25 {
                    try Task.checkCancellation()
                    cloudAttempts += 1
                    do {
                        let (reply, committed) = try await aggregateReadStep(reference,
                            generation: generation, request: .cloudSongs(cursor: aggregateCache.cloudNext, limit: aggregateCache.cloudReadLimit),
                            deadline: min(workEnd, ProcessInfo.processInfo.systemUptime + 7), transport: transport)
                        generation = committed.generation
                        cloudResult = reply; session = reply.session
                        guard reply.state == .authorizedRead, let payload = reply.payload else { break }
                        do { try aggregateCache.ingestCloud(payload, now: musicSearchNow()) }
                        catch CredentialError.uncertainLocalState {
                            cloudResult = .init(state: .contractRejected, session: reply.session, payload: nil)
                            break
                        }
                        if !aggregateCache.cloudEnd && aggregateCache.cloudNext == nil { break }
                    } catch TransportFailure.timeout { cloudTimedOut = true; break }
                      catch TransportFailure.network { cloudTimedOut = true; break }
                }
                // Failure, cancellation, capacity or deadline never deletes prior indexed songs.
                aggregateCache.endCloudRefresh(now: musicSearchNow(), succeeded: aggregateCache.cloudEnd && cloudResult?.state == .authorizedRead)
            }
            try Task.checkCancellation()
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            guard let current = try repository.metadata(reference.purpose), current.reference == reference,
                  current.generation == generation else { throw CredentialError.staleReference }
            let now = musicSearchNow()
            let publicStatus = MusicAggregateSourceStatus(
                state: publicTimedOut ? "runtime_failed" : publicResult?.state.rawValue ?? (progress.publicStarted ? "cached" : "not_attempted"),
                coverage: progress.publicEnded ? "end_observed" : progress.publicStarted ? "partial" : "not_started",
                scannedCount: progress.publicScanned,
                cachedCount: progress.publicPending.count, total: progress.publicPage?.total, cacheAgeSeconds: nil,
                readAttempts: publicAttempted ? 1 : 0, failure: publicResult?.failure, nextPageAvailable: progress.publicNext != nil)
            let statuses = ["public_catalog": publicStatus,
                "private_cloud": aggregateCache.cloudStatus(result: cloudResult, runtimeFailed: cloudTimedOut, attempts: cloudAttempts, now: now)]
            return try aggregateCache.finish(query: query, progress: progress, statuses: statuses, session: session, now: now)
        } catch {
            aggregateCache.endCloudRefresh(now: musicSearchNow(), succeeded: false)
            // Ordinary network/permission failures retain metadata. Only a proved account/generation change invalidates it.
            if let current = try? repository.metadata(reference.purpose) {
                if current.reference != reference || current.generation != aggregateCache.generation { aggregateCache = .init() }
            } else if (error as? CredentialError) == .staleReference || (error as? CredentialError) == .missing {
                aggregateCache = .init()
            }
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            throw error
        }
    }
    private func commitMusicLease(_ reference: CredentialReference, input: CredentialInput,
                                  result: ConnectionTestResult?, expectedGeneration: UUID) throws -> StoredMetadata {
        let committed = try repository.commitLease(reference, input: input, result: result, expectedGeneration: expectedGeneration)
        // Preserve this account's index across the owner's own session-envelope rotation.
        // Explicit login/replacement/disconnect already invalidate via rotateMusicEpoch.
        if aggregateCache.reference == reference {
            if aggregateCache.generation == expectedGeneration {
                try aggregateCache.advanceGeneration(from: expectedGeneration, to: committed.generation)
            } else { aggregateCache = .init() }
        }
        return committed
    }
    private func aggregateReadStep(_ reference: CredentialReference, generation: UUID,
                                   request: MusicReadRequest, deadline: TimeInterval, transport: any MusicReadTransport) async throws
        -> (MusicReadResult, StoredMetadata) {
        let lease = try repository.lease(reference)
        defer { lease.secret.clear() }
        guard lease.metadata.generation == generation else { throw CredentialError.staleReference }
        musicProcessBarrier = transport as? any MusicProcessBarrier
        do {
            let reply = try await MusicSearchReadDeadline.$current.withValue(deadline) {
                try await transport.sendRead(lease.secret, request: request)
            }
            defer { reply.credential.clear() }
            do {
                try Task.checkCancellation()
                guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
                let committed = try commitMusicLease(reference, input: reply.credential,
                    result: .init(reply.result.connectionState), expectedGeneration: generation)
                return (reply.result, committed)
            } catch { reply.credential.clear(); throw error }
        } catch {
            guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
            throw error
        }
    }

    private func rotateMusicEpoch(_ reference: CredentialReference) throws {
        aggregateCache = .init() // Explicit login, replacement and disconnect invalidate private metadata immediately.
        try writeJournal?.transaction { ledger in ledger.epochs[reference.id.uuidString] = UUID() }
    }
    public func musicConnectionStatus() async throws -> MusicConnectionStatus {
        let current = snapshot(purpose: .neteaseMusic)
        guard let reference = current.reference else {
            return .init(state: current.state == .localStorageUnavailable ? "owner_unavailable" : "requires_setup", ready: false, configuration: current.state.rawValue,
                         login: "not_checked", writes: current.state == .localStorageUnavailable ? "unavailable" : "requires_setup")
        }
        let checked = try await consumeRead(reference, request: .userPlaylists)
        let ready = checked.state == .authorizedRead
        let setup = checked.state == .loginRequired || checked.state == .refreshRejected
        return .init(state: ready ? "ready" : setup ? "requires_setup" : "provider_unavailable", ready: ready,
                     configuration: "configured", login: ready ? "authorized" : setup ? "login_required" : "unconfirmed",
                     writes: ready && musicWrites != nil && writeJournal != nil ? "explicit_user_request" : setup ? "requires_setup" : "unavailable")
    }
    // A write holds the purpose slot across preflight, durable reservation,
    // one effect and readback. Each subprocess must reap before the next step.
    /// URL/ref are normal product inputs; all hashes, file paths, account epoch
    /// and readback baselines are internal to the owner.
    public func consumeCover(_ reference: CredentialReference, request: MusicPlaylistCoverRequest, resumeNotDispatched: Bool = false) async throws -> MusicPlaylistCoverResult {
        let trace = MusicDiagnostics.current ?? MusicDiagnosticTrace(requestID: request.requestID)
        return try await MusicDiagnostics.$current.withValue(trace) {
            refreshMusicCleanupBarrier()
            guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
            guard !testing.contains(.neteaseMusic) else { throw CredentialError.busy }
            guard let coverJournal, let writeJournal, let musicCovers, musicReads != nil else { throw CredentialError.deploymentNotApproved }
            let admission = try repository.lease(reference); admission.secret.clear()
            testing.insert(.neteaseMusic)
            defer { _ = finishMusicOperation() }
            let epoch: UUID
            if let value = try writeJournal.inspect()?.epochs[reference.id.uuidString] { epoch = value }
            else if request.reconcileOnly { return .init("record_missing", request: request) }
            else {
                epoch = try writeJournal.transaction { ledger in
                    if let value = ledger.epochs[reference.id.uuidString] { return value }
                    let value = UUID(); ledger.epochs[reference.id.uuidString] = value; return value
                }
            }
            if try writeJournal.inspect()?.records[request.requestID.uuidString] != nil { return .init("request_conflict", request: request) }
            if let record = try coverJournal.inspect(request.requestID) {
                guard record.request == request else { return .init("request_conflict", request: request) }
                guard record.reference == reference.id, record.epoch == epoch else { return .init("account_changed", request: request) }
                if let file = coverJournal as? FileMusicPlaylistCoverJournal {
                    let recovery = try file.inspectRecovery(request.requestID)
                    if let latest = recovery?.attempts.last, let count = recovery?.attempts.count {
                        if latest.record.result == nil {
                            return try await reconcileCoverRecord(reference, record: latest.record, journal: file, recoveryAttempt: count)
                        }
                        if !resumeNotDispatched || request.reconcileOnly { return recoveryResult(latest.record.result!, attempt: count) }
                        let generation = try musicCovers.coverRuntimeGeneration()
                        if recovery!.attempts.contains(where: { $0.generation == generation }) || !FileMusicPlaylistCoverJournal.tokenFailure(latest.record) {
                            return recoveryResult(latest.record.result!, attempt: count)
                        }
                    }
                    if resumeNotDispatched, !request.reconcileOnly, record.effectState == "not_submitted", record.result?.state == "not_dispatched" {
                        return try await resumeCoverTokenFailure(reference, original: record, epoch: epoch, journal: file, transport: musicCovers)
                    }
                }
                if let result = record.result { return result }
                return try await reconcileCoverRecord(reference, record: record, journal: coverJournal)
            }
            guard !request.reconcileOnly else { return .init("record_missing", request: request) }
            try Task.checkCancellation()
            let owned = try await writeReadStep(reference, request: .userPlaylists)
            guard owned.state == .authorizedRead, owned.providerResult == nil, let listed = owned.payload,
                  listed.playlists?.contains(where: { $0.playlistID == request.playlistID }) == true else {
                return .init(owned.payload?.complete == true ? "target_mismatch" : "incomplete_read", request: request)
            }
            let before = try await writeReadStep(reference, request: .playlistDetail(playlistID: request.playlistID))
            guard before.state == .authorizedRead, before.providerResult == nil, let detail = before.payload, detail.playlist?.playlistID == request.playlistID else {
                return .init("incomplete_read", request: request)
            }
            let imageURL: URL
            if let value = request.imageURL { imageURL = value }
            else {
                guard let song = detail.songs?.first(where: { $0.songID == request.imageReference }),
                      case .text(let text) = song.providerRecord?.fields["coverImgUrl"],
                      let value = MusicPlaylistCoverRequest.imageURL(text) else { return .init("image_reference_missing", request: request) }
                imageURL = value
            }
            let image = try await coverImages.load(imageURL)
            try Task.checkCancellation()
            let staged = try coverJournal.stage(image, id: request.requestID)
            func stagedOperation() async throws -> MusicPlaylistCoverResult {
                // Recheck the selected playlist after image download. A concurrent
                // custom cover change must not be overwritten by this reserved call.
                let fresh = try await writeReadStep(reference, request: .playlistDetail(playlistID: request.playlistID))
                guard fresh.state == .authorizedRead, fresh.providerResult == nil, let current = fresh.payload, current.playlist?.playlistID == request.playlistID,
                      MusicPlaylistCoverVerification.sameCover(MusicPlaylistCoverVerification.coverURL(current.playlist), MusicPlaylistCoverVerification.coverURL(detail.playlist)),
                      !detail.complete || current.complete && current.songs?.map(\.songID) == detail.songs?.map(\.songID)
                else { return .init("preflight_changed", request: request) }
                var record = MusicPlaylistCoverRecord(request: request, reference: reference.id, epoch: epoch,
                    baselineCover: MusicPlaylistCoverVerification.coverURL(current.playlist),
                    baselineSongs: current.complete ? current.songs?.map(\.songID) : nil)
                let lease = try repository.lease(reference); defer { lease.secret.clear() }
                try Task.checkCancellation()
                guard try writeJournal.inspect()?.epochs[reference.id.uuidString] == epoch else { return .init("account_changed", request: request) }
                try coverJournal.reserve(record) // durable before token/NOS/update
                musicProcessBarrier = musicCovers as? any MusicProcessBarrier
                do {
                    let effect = try await musicCovers.sendCover(lease.secret, request: .init(playlistID: request.playlistID,
                        fileURL: staged.fileURL, sha256: staged.sha256, bytes: staged.bytes))
                    defer { effect.credential.clear() }
                    guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    record.resourceID = effect.resourceID; record.effectState = effect.state
                    record.providerResponse = effect.providerResponse; record.providerResponseComplete = effect.providerResponseComplete
                    record.providerExchange = effect.providerExchange; record.uploadReceipts = effect.uploadReceipts
                    try coverJournal.save(record)
                    _ = try commitMusicLease(reference, input: effect.credential, result: nil, expectedGeneration: lease.metadata.generation)
                } catch {
                    guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    if error is MusicBusinessLogFailure { throw error }
                    if Task.isCancelled { throw CancellationError() }
                    // The durable reservation survives exceptions. Repeating this
                    // UUID only reads; no token, image upload or cover call is retried.
                }
                try Task.checkCancellation()
                return try await reconcileCoverRecord(reference, record: record, journal: coverJournal)
            }
            let result: MusicPlaylistCoverResult
            do { result = try await stagedOperation() }
            catch {
                // Unreserved failures recover under the image lock on the next
                // stage; terminal records retry cleanup during inspect. A pending
                // reservation remains reconciliation-only even if cleanup fails.
                do { try coverJournal.removeImage(staged.fileURL) } catch { }
                throw error
            }
            do { try coverJournal.removeImage(staged.fileURL); return result }
            catch { var reported = result; reported.stagedImageCleanup = "pending"; return reported }
        }
    }
    public func reconcileCover(_ reference: CredentialReference, requestID: UUID) async throws -> MusicPlaylistCoverResult? {
        guard let coverJournal else { return nil }
        guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
        let admission = try repository.lease(reference); admission.secret.clear()
        guard let record = try coverJournal.inspect(requestID) else { return nil }
        let request = try MusicPlaylistCoverRequest(requestID: record.request.requestID, playlistID: record.request.playlistID,
            imageURL: record.request.imageURL?.absoluteString, imageReference: record.request.imageReference, reconcileOnly: true)
        return try await consumeCover(reference, request: request)
    }
    private func recoveryResult(_ result: MusicPlaylistCoverResult, attempt: Int) -> MusicPlaylistCoverResult {
        var value = result; value.recoveryAttempt = attempt; value.originalState = "not_dispatched"; return value
    }
    /// Only the trusted owner route's explicit false grants this operation.
    private func resumeCoverTokenFailure(_ reference: CredentialReference, original: MusicPlaylistCoverRecord, epoch: UUID,
        journal: FileMusicPlaylistCoverJournal, transport: any MusicPlaylistCoverTransport) async throws -> MusicPlaylistCoverResult {
        let request = original.request
        let generation = try transport.coverRuntimeGeneration()
        let proof: MusicPlaylistCoverRecoveryProof
        do { proof = try journal.recoveryProof(request.requestID, generation: generation) }
        catch { var blocked = MusicPlaylistCoverResult("recovery_blocked", request: request); blocked.originalState = "not_dispatched"; return blocked }
        let owned = try await writeReadStep(reference, request: .userPlaylists)
        guard owned.state == .authorizedRead, owned.providerResult == nil, owned.payload?.complete == true,
              owned.payload?.playlists?.contains(where: { $0.playlistID == request.playlistID }) == true
              else { return .init("incomplete_read", request: request) }
        func matches(_ read: MusicReadResult) -> Bool {
            read.state == .authorizedRead && read.providerResult == nil && read.payload?.complete == true &&
            read.payload?.playlist?.playlistID == request.playlistID &&
            read.payload?.songs?.map(\.songID) == original.baselineSongs &&
            MusicPlaylistCoverVerification.resource(MusicPlaylistCoverVerification.coverURL(read.payload?.playlist)) ==
            MusicPlaylistCoverVerification.resource(original.baselineCover)
        }
        let before = try await writeReadStep(reference, request: .playlistDetail(playlistID: request.playlistID))
        guard matches(before) else { return .init("preflight_changed", request: request) }
        let url: URL
        if let value = request.imageURL { url = value }
        else {
            guard let song = before.payload?.songs?.first(where: { $0.songID == request.imageReference }),
                  case .text(let text) = song.providerRecord?.fields["coverImgUrl"], let value = MusicPlaylistCoverRequest.imageURL(text)
                  else { return .init("image_reference_missing", request: request) }
            url = value
        }
        let bytes = try await coverImages.load(url)
        guard bytes.count == proof.imageBytes, MusicRuntimeResources.hash(bytes) == proof.imageSHA256 else { return .init("image_changed", request: request) }
        try Task.checkCancellation()
        let staged = try journal.stageRecovery(bytes, id: request.requestID, generation: generation, proof: proof)
        func operation() async throws -> MusicPlaylistCoverResult {
            let fresh = try await writeReadStep(reference, request: .playlistDetail(playlistID: request.playlistID))
            guard matches(fresh) else { return .init("preflight_changed", request: request) }
            let lease = try repository.lease(reference); defer { lease.secret.clear() }
            guard try writeJournal?.inspect()?.epochs[reference.id.uuidString] == epoch,
                  try transport.coverRuntimeGeneration() == generation else { return .init("account_changed", request: request) }
            var record = MusicPlaylistCoverRecord(request: original.request, reference: original.reference, epoch: original.epoch,
                baselineCover: original.baselineCover, baselineSongs: original.baselineSongs)
            try Task.checkCancellation()
            let attempt = try journal.reserveRecovery(record, generation: generation, proof: proof)
            musicProcessBarrier = transport as? any MusicProcessBarrier
            do {
                let effect = try await transport.sendCover(lease.secret, request: .init(playlistID: request.playlistID,
                    fileURL: staged.fileURL, sha256: staged.sha256, bytes: staged.bytes))
                defer { effect.credential.clear() }
                guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
                record.resourceID = effect.resourceID; record.effectState = effect.state
                record.providerResponse = effect.providerResponse; record.providerResponseComplete = effect.providerResponseComplete
                record.providerExchange = effect.providerExchange; record.uploadReceipts = effect.uploadReceipts
                try journal.saveRecovery(record, attempt: attempt)
                _ = try commitMusicLease(reference, input: effect.credential, result: nil, expectedGeneration: lease.metadata.generation)
            } catch {
                guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
                if error is MusicBusinessLogFailure { throw error }
                if Task.isCancelled { throw CancellationError() }
            }
            try Task.checkCancellation()
            return try await reconcileCoverRecord(reference, record: record, journal: journal, recoveryAttempt: attempt)
        }
        let result: MusicPlaylistCoverResult
        do { result = try await operation() }
        catch { try? journal.removeImage(staged.fileURL); throw error }
        do { try journal.removeImage(staged.fileURL); return result }
        catch { var value = result; value.stagedImageCleanup = "pending"; return value }
    }
    private func reconcileCoverRecord(_ reference: CredentialReference, record: MusicPlaylistCoverRecord,
                                      journal: any MusicPlaylistCoverJournal, recoveryAttempt: Int? = nil) async throws -> MusicPlaylistCoverResult {
        var result = MusicPlaylistCoverResult(record.effectState == "not_submitted" ? "not_dispatched" :
            record.effectState == "provider_rejected" ? "provider_rejected" : "outcome_unknown", request: record.request)
        result.providerResponse = record.providerResponse; result.providerResponseComplete = record.providerResponseComplete ?? false
        result.providerExchange = record.providerExchange; result.uploadReceipts = record.uploadReceipts ?? []
        if record.resourceID != nil, record.effectState != "not_submitted" {
            let read = try await writeReadStep(reference, request: .playlistDetail(playlistID: record.request.playlistID))
            result.playlist = read.payload?.playlist
            if MusicPlaylistCoverVerification.verified(resourceID: record.resourceID, record: record, read: read) {
                result.state = "verified"; result.readbackVerified = true
            } else if read.state != .authorizedRead { result.state = "readback_failed" }
        }
        guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
        if result.readbackVerified || ["not_dispatched","provider_rejected"].contains(result.state) {
            // The terminal result owns the complete reply. Pending reconciliation
            // metadata must not persist a second complete copy of that same body.
            var finished = record; finished.result = result
            finished.providerResponse = nil; finished.providerResponseComplete = nil
            finished.providerExchange = nil; finished.uploadReceipts = nil
            if let recoveryAttempt, let file = journal as? FileMusicPlaylistCoverJournal { try file.saveRecovery(finished, attempt: recoveryAttempt) }
            else { try journal.save(finished) }
        }
        if let recoveryAttempt { return recoveryResult(result, attempt: recoveryAttempt) }
        return result
    }

    public func consumeWrite(_ reference: CredentialReference, request: MusicWriteRequest) async throws -> MusicWriteResult {
        let inherited = MusicDiagnostics.current
        let trace = inherited?.requestID == request.requestID ? inherited! : MusicDiagnosticTrace(requestID: request.requestID)
        return try await MusicDiagnostics.$current.withValue(trace) {
            trace.record(.owner, .started)
            do {
                let result = try await consumeWriteTracked(reference, request: request)
                trace.record(.complete, result.readbackVerified ? .succeeded : .unconfirmed)
                return result
            } catch {
                trace.fail(error, phase: .owner)
                throw error
            }
        }
    }
    /// Dedicated query: read an existing ID; no reservation, preflight or sendWrite path.
    public func reconcileWrite(_ reference: CredentialReference, requestID: UUID) async throws -> MusicReconciliationResult {
        let trace = MusicDiagnosticTrace(requestID: requestID)
        return try await MusicDiagnostics.$current.withValue(trace) {
            refreshMusicCleanupBarrier()
            guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
            guard !testing.contains(.neteaseMusic) else { throw CredentialError.busy }
            guard let journal = writeJournal, musicReads != nil else { throw CredentialError.deploymentNotApproved }
            try Task.checkCancellation()
            let admission = try repository.lease(reference); admission.secret.clear()
            guard let ledger = try journal.inspect(), let record = ledger.records[requestID.uuidString] else {
                return .init(requestID: requestID)
            }
            guard record.reference == reference.id, ledger.epochs[reference.id.uuidString] == record.epoch else {
                return .init(requestID: requestID, record: record, result: .init(.accountChanged, request: record.request))
            }
            if let recovery = try journal.inspectRecovery(requestID: requestID) {
                testing.insert(.neteaseMusic)
                do {
                    let result = try await reconcileRecovery(reference, original: record, recovery: recovery, journal: journal)
                    guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    return .init(requestID: requestID, record: record, result: result, recovery: .init(recovery))
                } catch {
                    guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    throw error
                }
            }
            if record.effectDisposition == .notDispatched {
                return .init(requestID: requestID, record: record, result: .init(.notDispatched, request: record.request, providerResult: record.providerResult))
            }
            if let result = record.result { return .init(requestID: requestID, record: record, result: result) }
            testing.insert(.neteaseMusic)
            do {
                let result = try await reconcileMusicWrite(reference, record: record)
                try finishWriteRecord(record, result: result, journal: journal)
                guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                return .init(requestID: requestID, record: record, result: result)
            } catch {
                guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                throw error
            }
        }
    }
    /// Explicit, bounded recovery of one existing append. No caller-selected target,
    /// new UUID, or missing-record creation. Repeated calls only reconcile after
    /// the single recovery reservation, including unknown or non-dispatched results.
    public func recoverAppendOnce(_ reference: CredentialReference, requestID: UUID) async throws -> MusicReconciliationResult {
        let trace = MusicDiagnosticTrace(requestID: requestID)
        return try await MusicDiagnostics.$current.withValue(trace) {
            refreshMusicCleanupBarrier()
            guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
            guard !testing.contains(.neteaseMusic) else { throw CredentialError.busy }
            guard let journal = writeJournal, musicReads != nil, musicWrites != nil else { throw CredentialError.deploymentNotApproved }
            try Task.checkCancellation()
            let admission = try repository.lease(reference); admission.secret.clear()
            guard let ledger = try journal.inspect(), let record = ledger.records[requestID.uuidString] else {
                return .init(requestID: requestID)
            }
            guard record.reference == reference.id, ledger.epochs[reference.id.uuidString] == record.epoch else {
                return .init(requestID: requestID, record: record, result: .init(.accountChanged, request: record.request))
            }
            guard record.request.intent == .appendSong, record.cloudResource == nil, !record.request.reconcileOnly else {
                return .init(requestID: requestID, record: record, result: .init(.requestConflict, request: record.request))
            }
            trace.record(.owner, .started)
            do {
                let result = try await consumeWriteTracked(reference, request: record.request, explicitAppendRecovery: true)
                trace.record(.complete, result.readbackVerified ? .succeeded : .unconfirmed)
                return .init(requestID: requestID, record: record, result: result,
                             recovery: try journal.inspectRecovery(requestID: requestID).map(MusicWriteRecoveryStatus.init))
            } catch {
                trace.fail(error, phase: .owner); throw error
            }
        }
    }
    /// A new, explicitly selected current cloud-file resource. The original
    /// UUID/target/recovery is immutable; a durable successor link bounds this
    /// operation independently of connection retries and token rotation.
    public func appendCurrentCloudSong(_ reference: CredentialReference, request: MusicCurrentCloudAppendRequest) async throws -> MusicCurrentCloudAppendResult {
        refreshMusicCleanupBarrier()
        guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
        guard !testing.contains(.neteaseMusic) else { throw CredentialError.busy }
        guard let journal = writeJournal, musicReads != nil, musicWrites != nil else { throw CredentialError.deploymentNotApproved }
        let lease = try repository.lease(reference); lease.secret.clear()
        guard let ledger = try journal.inspect(), let parent = ledger.records[request.supersedesRequestID.uuidString] else {
            return .init("record_missing", supersedes: request.supersedesRequestID)
        }
        guard parent.reference == reference.id, ledger.epochs[reference.id.uuidString] == parent.epoch else {
            return .init("account_changed", supersedes: request.supersedesRequestID)
        }
        guard parent.request.intent == .appendSong, parent.cloudResource == nil else {
            return .init("request_conflict", supersedes: request.supersedesRequestID)
        }
        if let existing = ledger.cloudSuccessor(of: request.supersedesRequestID) {
            guard existing.cloudResource?.resource.pcID == request.pcID else { return .init("request_conflict", supersedes: request.supersedesRequestID) }
            let query = try MusicWriteRequest(requestID: existing.request.requestID, intent: .appendSong,
                name: existing.request.name, playlistID: existing.request.playlistID, songID: existing.request.songID, reconcileOnly: true)
            let result = try await consumeWrite(reference, request: query)
            return .init(result.state.rawValue, supersedes: request.supersedesRequestID, context: existing.cloudResource, result: result)
        }
        guard parent.result == nil else { return .init("request_conflict", supersedes: request.supersedesRequestID) }
        guard let selection = aggregateCache.cloudSelection(request.selectionID, reference: reference, now: musicSearchNow()) else {
            return .init("selection_expired", supersedes: request.supersedesRequestID)
        }
        guard selection.selection.resource.pcID == request.pcID else { return .init("resource_identity_mismatch", supersedes: request.supersedesRequestID) }
        let resolved = try await resolveCurrentCloudSelection(reference, selection: selection)
        guard let resource = resolved.resource else { return .init(resolved.state, supersedes: request.supersedesRequestID) }
        guard resource.songID != parent.request.songID else { return .init("resource_unchanged", supersedes: request.supersedesRequestID) }
        if let other = ledger.cloudReservation(reference: reference.id, epoch: parent.epoch,
            playlistID: parent.request.playlistID!, pcID: resource.pcID) {
            return .init("request_conflict", supersedes: request.supersedesRequestID, context: other.cloudResource)
        }
        let context = MusicCloudOperationContext(supersedesRequestID: request.supersedesRequestID,
            selectedResource: selection.selection.resource, resource: resource, observedAt: musicSearchNow())
        let id = context.operationID(reference: reference.id, epoch: parent.epoch)
        let current = try MusicWriteRequest(requestID: id, intent: .appendSong, name: parent.request.name,
            playlistID: parent.request.playlistID, songID: resource.songID)
        let trace = MusicDiagnosticTrace(requestID: id)
        return try await MusicDiagnostics.$current.withValue(trace) {
            trace.record(.owner, .started)
            do {
                let result = try await consumeWriteTracked(reference, request: current, cloudResource: context, cloudEpoch: parent.epoch)
                trace.record(.complete, result.readbackVerified ? .succeeded : .unconfirmed)
                return .init(result.state.rawValue, supersedes: request.supersedesRequestID, context: context, result: result)
            } catch { trace.fail(error, phase: .owner); throw error }
        }
    }
    private func resolveCurrentCloudSelection(_ reference: CredentialReference, selection: MusicAggregateSearchCache.CloudReceipt) async throws
        -> (state: String, resource: MusicCloudResource?) {
        guard !testing.contains(.neteaseMusic) else { throw CredentialError.busy }
        testing.insert(.neteaseMusic)
        do {
            var cursor = selection.cursor
            for _ in 0..<2 {
                let read = try await writeReadStep(reference, request: .cloudSongs(cursor: cursor, limit: selection.limit))
                guard read.state == .authorizedRead, read.providerResult == nil, let payload = read.payload,
                      let rows = payload.songs, let page = payload.cloudPage else {
                    guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    return ("resource_unresolved", nil)
                }
                let matches = rows.compactMap { row -> (MusicReadSong, MusicCloudResource)? in
                    guard let resource = MusicCloudResource(row), resource.pcID == selection.selection.resource.pcID else { return nil }
                    return (row, resource)
                }
                if !matches.isEmpty {
                    guard matches.count == 1, matches[0].1.sameFileIdentity(as: selection.selection.resource) else {
                        guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                        return ("resource_identity_mismatch", nil)
                    }
                    let resource = try aggregateCache.retainPointSelection(matches[0].0, cursor: cursor, limit: page.limit, now: musicSearchNow())
                    guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    return ("resolved", resource)
                }
                guard let next = page.nextCursor, next != cursor else { break }
                cursor = next
            }
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            return ("resource_unresolved", nil)
        } catch {
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            throw error
        }
    }
    private func consumeWriteTracked(_ reference: CredentialReference, request: MusicWriteRequest,
                                     explicitAppendRecovery: Bool = false, cloudResource: MusicCloudOperationContext? = nil, cloudEpoch: UUID? = nil) async throws -> MusicWriteResult {
        try request.validate(); refreshMusicCleanupBarrier()
        guard reference.purpose == .neteaseMusic else { throw CredentialError.wrongPurpose }
        guard !testing.contains(.neteaseMusic) else { throw CredentialError.busy }
        guard let journal = writeJournal, let musicWrites, musicReads != nil else { throw CredentialError.deploymentNotApproved }
        try Task.checkCancellation()
        // Gate and validate the selected native reference before local journal IO.
        let admission = try repository.lease(reference); admission.secret.clear()
        if try coverJournal?.inspect(request.requestID) != nil { return .init(.requestConflict, request: request) }
        testing.insert(.neteaseMusic)
        do {
            let observed = try journal.inspect()
            // Existing requests, including recovery, never rewrite the original ledger.
            let epoch: UUID
            if let stored = observed?.epochs[reference.id.uuidString] { epoch = stored }
            else {
                if request.reconcileOnly { _ = finishMusicOperation(); return .init(.outcomeUnknown, request: request) }
                epoch = try journal.transaction { ledger in
                    if let stored = ledger.epochs[reference.id.uuidString] { return stored }
                    let value = UUID(); ledger.epochs[reference.id.uuidString] = value; return value
                }
            }
            if let cloudResource {
                guard cloudEpoch == epoch, let parent = observed?.records[cloudResource.supersedesRequestID.uuidString],
                      parent.reference == reference.id, parent.epoch == epoch, parent.cloudResource == nil,
                      parent.request.playlistID == request.playlistID, parent.request.name == request.name,
                      parent.request.songID != request.songID,
                      cloudResource.operationID(reference: reference.id, epoch: epoch) == request.requestID,
                      musicSearchNow() >= cloudResource.observedAt, musicSearchNow() - cloudResource.observedAt <= 90
                else { _ = finishMusicOperation(); return .init(.accountChanged, request: request) }
            }
            let existing = observed?.records[request.requestID.uuidString]
            if explicitAppendRecovery, existing == nil { _ = finishMusicOperation(); throw CredentialError.missing }
            var recovering = false
            if let existing {
                guard existing.request == request else { _ = finishMusicOperation(); return .init(.requestConflict, request: request) }
                guard existing.reference == reference.id, existing.epoch == epoch else { _ = finishMusicOperation(); return .init(.accountChanged, request: request) }
                if let result = existing.result { _ = finishMusicOperation(); return result }
                if existing.cloudResource != nil {
                    if existing.effectDisposition == .notDispatched { _ = finishMusicOperation(); return .init(.notDispatched, request: request, providerResult: existing.providerResult) }
                    let result = try await reconcileMusicWrite(reference, record: existing)
                    try finishWriteRecord(existing, result: result, journal: journal)
                    guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    return result
                }
                var recovery = try journal.inspectRecovery(requestID: request.requestID)
                if recovery == nil, !request.reconcileOnly,
                   existing.effectDisposition == .notDispatched || explicitAppendRecovery {
                    recovery = try journal.recoveryTransaction { originals, retries in
                        guard let original = originals.records[request.requestID.uuidString],
                              original == existing, originals.epochs[reference.id.uuidString] == epoch
                        else { throw CredentialError.staleReference }
                        if let current = retries.records[request.requestID.uuidString] { return current }
                        let value = MusicWriteRecoveryRecord(request: original.request, reference: reference.id,
                            epoch: epoch, reason: explicitAppendRecovery ? .duplicateSafeAppendOnce : .notDispatched, decidedAt: Date())
                        retries.records[request.requestID.uuidString] = value; return value
                    }
                }
                if let recovery {
                    if !request.reconcileOnly,
                       explicitAppendRecovery ? recovery.mayReserveAppendOnce : recovery.mayReserve { recovering = true }
                    else {
                        let result = try await reconcileRecovery(reference, original: existing, recovery: recovery, journal: journal)
                        guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                        return result
                    }
                } else {
                    if existing.effectDisposition == .notDispatched { _ = finishMusicOperation(); return .init(.notDispatched, request: request, providerResult: existing.providerResult) }
                    let result = try await reconcileMusicWrite(reference, record: existing)
                    try finishWriteRecord(existing, result: result, journal: journal)
                    guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    return result
                }
            }
            if request.reconcileOnly {
                _ = finishMusicOperation(); return .init(.outcomeUnknown, request: request)
            }
            var baselineSongIDs: [String]?
            var metadataDigest: String?
            let preflightStarted = ProcessInfo.processInfo.systemUptime
            let owned = try await writeReadStep(reference, request: .userPlaylists)
            guard owned.state == .authorizedRead, owned.providerResult == nil, let payload = owned.payload else {
                _ = finishMusicOperation(); return musicReadStopped(owned.state == .loginRequired || owned.state == .refreshRejected ? .requiresSetup : .providerUnavailable, request: request, read: owned, stage: "preflight")
            }
            let playlists = payload.playlists ?? []
            if explicitAppendRecovery, !payload.complete {
                _ = finishMusicOperation(); return .init(.incompleteRead, request: request)
            }
            if request.intent == .createPlaylist {
                guard payload.complete else { _ = finishMusicOperation(); return .init(.incompleteRead, request: request) }
                if recovering, playlists.contains(where: { $0.name == request.name }), let existing,
                   let recovery = try journal.inspectRecovery(requestID: request.requestID) {
                    // A same-name target may already be the successful original.
                    // Resolve its identity; never create another on ambiguity.
                    let result = try await reconcileRecovery(reference, original: existing, recovery: recovery, journal: journal)
                    guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                    return result
                }
            } else {
                guard playlists.contains(where: { $0.playlistID == request.playlistID && $0.name == request.name }) else {
                    _ = finishMusicOperation(); return .init(payload.complete ? .targetMismatch : .incompleteRead, request: request)
                }
                let before = try await writeReadStep(reference, request: .playlistDetail(playlistID: request.playlistID!))
                guard before.state == .authorizedRead, before.providerResult == nil, let detail = before.payload, detail.complete, detail.songs != nil else {
                    _ = finishMusicOperation(); return musicReadStopped(.incompleteRead, request: request, read: before, stage: "preflight")
                }
                guard detail.playlist?.playlistID == request.playlistID, detail.playlist?.name == request.name else {
                    _ = finishMusicOperation(); return .init(.targetMismatch, request: request)
                }
                // Re-observe complete membership immediately before effect reservation.
                // Equality is not an atomic snapshot; external edits can still race.
                let verified = detail // The runtime already completed two ordered sweeps and target readback.
                if request.isSongListUpdate {
                    let current = verified.songs!.map(\.songID), requested = request.songIDs!
                    guard request.intent != .reorderSongs || Set(current) == Set(requested),
                          request.intent != .removeSongs || Set(requested).isSubset(of: Set(current)) else {
                        _ = finishMusicOperation(); return .init(.targetMismatch, request: request, readbackState: "requested_songs_do_not_match_current_playlist")
                    }
                    baselineSongIDs = current
                }
                if request.isMetadataUpdate {
                    guard request.intent != .updatePlaylistDescription ||
                        (MusicWriteRequest.playlistDescription(detail.playlist) != nil && MusicWriteRequest.playlistDescription(detail.playlist) == MusicWriteRequest.playlistDescription(verified.playlist))
                    else { _ = finishMusicOperation(); return .init(.incompleteRead, request: request, readbackState: "description_unavailable_or_changed") }
                    metadataDigest = try MusicWriteRequest.contentsDigest(verified.songs!)
                }
                if request.intent == .appendSong, let matched = verified.songs?.first(where: { song in
                    song.songID == request.songID || cloudResource.map { target in MusicCloudResource(song)?.sameFileIdentity(as: target.resource) == true } == true
                }) {
                    let result = MusicWriteResult(.alreadyPresent, request: request, matchedSongID: matched.songID == request.songID ? nil : matched.songID)
                    let record = MusicWriteRecord(request: request, reference: reference.id, epoch: epoch,
                        baseline: playlists.map(\.playlistID), result: result, cloudResource: cloudResource)
                    if recovering {
                        try saveRecoveryResult(requestID: request.requestID, reference: reference.id, epoch: epoch, result: result, journal: journal)
                    } else {
                        try journal.transaction { ledger in
                            guard ledger.epochs[reference.id.uuidString] == epoch, ledger.records[request.requestID.uuidString] == nil else { throw CredentialError.busy }
                            ledger.records[request.requestID.uuidString] = record
                        }
                    }
                    _ = finishMusicOperation(); return result
                }
            }
            guard ProcessInfo.processInfo.systemUptime - preflightStarted <= 90,
                  cloudResource.map({ musicSearchNow() >= $0.observedAt && musicSearchNow() - $0.observedAt <= 90 }) ?? true else {
                _ = finishMusicOperation(); return .init(.incompleteRead, request: request)
            }
            var record = MusicWriteRecord(request: request, reference: reference.id, epoch: epoch, baseline: playlists.map(\.playlistID), baselineSongIDs: baselineSongIDs, contentDigest: metadataDigest, cloudResource: cloudResource)
            try Task.checkCancellation()
            let lease = try repository.lease(reference); defer { lease.secret.clear() }
            if recovering {
                try journal.recoveryTransaction { originals, retries in
                    guard originals.epochs[reference.id.uuidString] == epoch,
                          originals.records[request.requestID.uuidString] == existing,
                          var retry = retries.records[request.requestID.uuidString],
                          explicitAppendRecovery ? retry.mayReserveAppendOnce : retry.mayReserve,
                          retry.request == request, retry.reference == reference.id, retry.epoch == epoch
                    else { throw CredentialError.busy }
                    if explicitAppendRecovery {
                        retry.appendDecision = .init(contract: MusicWriteRecoveryRecord.AppendDecision.currentContract,
                                                     priorAttemptCount: retry.attempts.count, decidedAt: Date())
                    }
                    retry.attempts.append(record); retries.records[request.requestID.uuidString] = retry
                }
            } else {
                try journal.transaction { ledger in
                    guard ledger.epochs[reference.id.uuidString] == epoch, ledger.records[request.requestID.uuidString] == nil else { throw CredentialError.busy }
                    ledger.records[request.requestID.uuidString] = record
                }
            }
            // Every exception after reservation leaves the durable record pending.
            // Ordinary retries only reconcile. A separate explicit append recovery
            // has its own durable once-only reservation and never resets this attempt.
            musicProcessBarrier = musicWrites as? any MusicProcessBarrier
            var dispositionPersisted = false
            do {
                MusicDiagnostics.current?.record(.effect, .started)
                let effect = try await musicWrites.sendWrite(lease.secret, request: request)
                MusicDiagnostics.current?.record(.effect, effect.state == .notSubmitted ? .not_dispatched : effect.state == .submitted ? .succeeded : .unconfirmed)
                defer { effect.credential.clear() }
                guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
                record.effectDisposition = effect.state == .notSubmitted ? .notDispatched : effect.state == .submitted ? .submitted : .outcomeUnknown
                record.returnedPlaylistID = effect.playlistID
                record.providerResult = effect.providerResult
                if recovering {
                    try journal.recoveryTransaction { originals, retries in
                        guard originals.epochs[reference.id.uuidString] == epoch,
                              var retry = retries.records[request.requestID.uuidString],
                              let current = retry.attempts.last, current.request == request,
                              current.epoch == epoch, current.effectDisposition == nil, current.result == nil
                        else { throw CredentialError.uncertainLocalState }
                        retry.attempts[retry.attempts.count - 1] = record
                        retries.records[request.requestID.uuidString] = retry
                    }
                } else {
                    try journal.transaction { ledger in
                        guard let current = ledger.records[request.requestID.uuidString], current.request == request,
                              current.epoch == epoch, current.result == nil else { throw CredentialError.uncertainLocalState }
                        ledger.records[request.requestID.uuidString] = record
                    }
                }
                dispositionPersisted = true
                _ = try commitMusicLease(reference, input: effect.credential, result: nil, expectedGeneration: lease.metadata.generation)
            } catch {
                MusicDiagnostics.current?.fail(error, phase: .effect)
                guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
                if record.effectDisposition != nil && !dispositionPersisted { throw error }
                // A log failure is independent of the business effect, which may
                // already have happened. Keep its reservation pending and report
                // the log error; do not hide it behind automatic readback success.
                if error is MusicBusinessLogFailure { throw error }
                if Task.isCancelled { throw CancellationError() }
                // Transport errors are uncertain effects; readback below is the
                // only success evidence. This reserved attempt is never reissued.
            }
            try Task.checkCancellation()
            if record.effectDisposition == .notDispatched {
                guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
                return .init(.notDispatched, request: request, providerResult: record.providerResult)
            }
            let result = try await reconcileMusicWrite(reference, record: record)
            if recovering {
                try saveRecoveryResult(requestID: request.requestID, reference: reference.id, epoch: epoch, result: result, journal: journal)
            } else { try finishWriteRecord(record, result: result, journal: journal) }
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            return result
        } catch {
            guard finishMusicOperation() else { throw MusicReadRuntimeFailure.cleanupUnproven }
            throw error
        }
    }
    private static func samePlaylistTargets(_ lhs: [MusicReadPlaylist]?, _ rhs: [MusicReadPlaylist]?) -> Bool {
        guard let lhs, let rhs, lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { item in rhs.contains { $0.playlistID == item.playlistID && $0.name == item.name } }
    }
    private func reconcileRecovery(_ reference: CredentialReference, original: MusicWriteRecord,
                                   recovery: MusicWriteRecoveryRecord, journal: any MusicWriteJournal) async throws -> MusicWriteResult {
        if let result = recovery.reconciled { return result }
        if let result = recovery.attempts.last?.result { return result }
        if let latest = recovery.attempts.last, latest.effectDisposition == .notDispatched {
            return .init(.notDispatched, request: original.request, providerResult: latest.providerResult)
        }
        let result = try await reconcileMusicWrite(reference, record: recovery.attempts.last ?? original)
        try saveRecoveryResult(requestID: original.request.requestID, reference: original.reference,
                               epoch: original.epoch, result: result, journal: journal)
        return result
    }
    private func saveRecoveryResult(requestID: UUID, reference: UUID, epoch: UUID,
                                    result: MusicWriteResult, journal: any MusicWriteJournal) throws {
        guard result.readbackVerified else { return }
        try journal.recoveryTransaction { originals, retries in
            guard originals.epochs[reference.uuidString] == epoch, var retry = retries.records[requestID.uuidString],
                  retry.reference == reference, retry.epoch == epoch else { throw CredentialError.staleReference }
            retry.reconciled = result; retries.records[requestID.uuidString] = retry
        }
    }
    private func writeReadStep(_ reference: CredentialReference, request: MusicReadRequest) async throws -> MusicReadResult {
        guard let musicReads else { throw CredentialError.deploymentNotApproved }
        try Task.checkCancellation()
        let lease = try repository.lease(reference); defer { lease.secret.clear() }
        musicProcessBarrier = musicReads as? any MusicProcessBarrier
        let reply = try await MusicReadPurpose.$verification.withValue(true) {
            try await musicReads.sendRead(lease.secret, request: request)
        }; defer { reply.credential.clear() }
        guard finishMusicOperation(releaseSlot: false) else { throw MusicReadRuntimeFailure.cleanupUnproven }
        _ = try commitMusicLease(reference, input: reply.credential, result: .init(reply.result.connectionState), expectedGeneration: lease.metadata.generation)
        try Task.checkCancellation(); return reply.result
    }
    private func musicReadStopped(_ state: MusicWriteResult.State, request: MusicWriteRequest, read: MusicReadResult,
                                  stage: String, providerResult: MusicProviderRecord? = nil) -> MusicWriteResult {
        .init(state, request: request, providerResult: providerResult, readbackFailure: read.failure,
              readbackProviderResult: read.providerResult ?? read.failure?.providerResult ?? read.payload?.pagination?.terminalObservations?.last,
              readbackState: stage + "_" + read.state.rawValue)
    }
    private func reconcileMusicWrite(_ reference: CredentialReference, record: MusicWriteRecord) async throws -> MusicWriteResult {
        MusicDiagnostics.current?.record(.readback, .started)
        let request = record.request
        let unknown = MusicWriteResult(.outcomeUnknown, request: request, providerResult: record.providerResult)
        var target = request.playlistID ?? record.returnedPlaylistID
        if target == nil {
            let read = try await writeReadStep(reference, request: .userPlaylists)
            guard read.state == .authorizedRead, read.providerResult == nil, let payload = read.payload else {
                return musicReadStopped(.readbackFailed, request: request, read: read, stage: "readback", providerResult: record.providerResult)
            }
            guard payload.complete else { return musicReadStopped(.incompleteRead, request: request, read: read, stage: "readback", providerResult: record.providerResult) }
            let candidates = (payload.playlists ?? []).filter { $0.name == request.name && !record.baseline.contains($0.playlistID) }
            guard candidates.count == 1 else { return unknown }
            target = candidates[0].playlistID
        }
        guard let target else { return unknown }
        let read = try await writeReadStep(reference, request: .playlistDetail(playlistID: target))
        guard read.state == .authorizedRead, read.providerResult == nil, let payload = read.payload else {
            return .init(.readbackFailed, request: request, playlistID: target, providerResult: record.providerResult,
                         readbackFailure: read.failure, readbackProviderResult: read.providerResult ?? read.failure?.providerResult ?? read.payload?.pagination?.terminalObservations?.last, readbackState: read.state.rawValue)
        }
        guard payload.playlist?.playlistID == target, payload.playlist?.name == (request.intent == .updatePlaylistName ? request.value : request.name) else {
            return .init(.targetMismatch, request: request, providerResult: record.providerResult, readbackState: "target_mismatch")
        }
        guard payload.complete, (request.intent == .createPlaylist || payload.songs != nil) else {
            return musicReadStopped(.incompleteRead, request: request, read: read, stage: "readback", providerResult: record.providerResult)
        }
        if request.isMetadataUpdate {
            guard try MusicWriteRequest.contentsDigest(payload.songs!) == record.contentDigest else {
                return .init(.readbackFailed, request: request, providerResult: record.providerResult, readbackState: "playlist_contents_changed")
            }
            if request.intent == .updatePlaylistDescription {
                guard let value = MusicWriteRequest.playlistDescription(payload.playlist), value == request.value else {
                    return .init(.readbackFailed, request: request, providerResult: record.providerResult, readbackState: "description_unavailable_or_mismatch")
                }
            }
        }
        var tagsReadbackRecord: MusicProviderRecord?
        if request.intent == .updatePlaylistTags {
            var actual = MusicWriteRequest.playlistTags(payload.playlist)
            if actual == nil {
                // The official detail endpoint returns tags:null even after a
                // successful update; created returns the target's actual tags.
                let owned = try await writeReadStep(reference, request: .userPlaylists)
                guard owned.state == .authorizedRead, owned.providerResult == nil, let listed = owned.payload else {
                    return musicReadStopped(.readbackFailed, request: request, read: owned, stage: "tags_readback_created", providerResult: record.providerResult)
                }
                let matches = (listed.playlists ?? []).filter { $0.playlistID == target }
                guard matches.count == 1, matches[0].name == request.name else {
                    return .init(listed.complete ? .targetMismatch : .incompleteRead, request: request, providerResult: record.providerResult, readbackState: "tags_created_target_unavailable")
                }
                // A complete matching target record is sufficient; other pages
                // do not alter this target's observed tags or the detail digest.
                actual = MusicWriteRequest.playlistTags(matches[0])
                tagsReadbackRecord = matches[0].providerRecord
            }
            guard let actual, Set(actual) == Set(request.tags!), actual.count == request.tags!.count else {
                return .init(.readbackFailed, request: request, providerResult: record.providerResult, readbackProviderResult: tagsReadbackRecord, readbackState: "tags_unavailable_or_mismatch")
            }
        }
        if request.isSongListUpdate {
            guard let before = record.baselineSongIDs else { return unknown }
            let after = payload.songs!.map(\.songID), wanted = request.songIDs!, selected = Set(wanted)
            let matches: Bool
            switch request.intent {
            case .reorderSongs: matches = after == wanted
            case .removeSongs: matches = after == before.filter { !selected.contains($0) }
            case .addSongs:
                let previous = Set(before)
                matches = selected.isSubset(of: Set(after)) && after.filter { previous.contains($0) } == before && Set(after) == previous.union(selected)
            default: matches = false
            }
            guard matches else { return .init(.readbackFailed, request: request, providerResult: record.providerResult, readbackState: "complete_playlist_does_not_match_requested_effect") }
        }
        var matchedSongID: String?
        if request.intent == .appendSong {
            guard let matched = payload.songs?.first(where: { song in
                song.songID == request.songID || record.cloudResource.map { target in MusicCloudResource(song)?.sameFileIdentity(as: target.resource) == true } == true
            }) else { return .init(.songAbsent, request: request, providerResult: record.providerResult, readbackState: "complete_song_absent") }
            matchedSongID = matched.songID == request.songID ? nil : matched.songID
        }
        return .init(.verified, request: request, playlistID: target, providerResult: record.providerResult, readbackProviderResult: tagsReadbackRecord ?? read.providerResult ?? read.payload?.pagination?.terminalObservations?.last, readbackState: tagsReadbackRecord == nil ? "verified" : "verified_tags_from_created", matchedSongID: matchedSongID)
    }
    private func finishWriteRecord(_ record: MusicWriteRecord, result: MusicWriteResult, journal: any MusicWriteJournal) throws {
        guard result.readbackVerified else { return } // Unknown records remain pending forever; no automatic expiry/retry.
        try journal.transaction { ledger in
            guard var current = ledger.records[record.request.requestID.uuidString], current.request == record.request,
                  current.reference == record.reference, current.epoch == record.epoch,
                  ledger.epochs[record.reference.uuidString] == record.epoch else { throw CredentialError.uncertainLocalState }
            current.result = result; ledger.records[record.request.requestID.uuidString] = current
        }
    }

    /// Inspection is synchronous and belongs to the same retained process owner as the transport.
    /// An idle owner alone cannot release a pending barrier: the exact prior generation must be reaped.
    private func refreshMusicCleanupBarrier() {
        guard musicCleanupPending, let generation = musicPendingCleanupGeneration,
              let status = musicProcessBarrier?.cleanupStatus(), status.provedIdle,
              status.lastReapedGeneration == generation else { return }
        musicCleanupPending = false; musicPendingCleanupGeneration = nil; musicProcessBarrier = nil
        testing.remove(.neteaseMusic)
    }
    @discardableResult private func finishMusicOperation(releaseSlot: Bool = true) -> Bool {
        guard let musicProcessBarrier else { if releaseSlot { testing.remove(.neteaseMusic) }; return true }
        let status = musicProcessBarrier.cleanupStatus()
        if musicCleanupPending {
            refreshMusicCleanupBarrier()
            return !musicCleanupPending
        }
        guard status.provedIdle else {
            musicCleanupPending = true; musicPendingCleanupGeneration = status.generation
            return false
        }
        if releaseSlot { testing.remove(.neteaseMusic) }
        self.musicProcessBarrier = nil
        return true
    }
    public func disconnect(_ reference: CredentialReference) throws -> LocalDisconnectReceipt {
        guard reference.purpose != .nasSMB else { throw CredentialError.wrongPurpose }
        refreshMusicCleanupBarrier()
        guard !testing.contains(reference.purpose) else { throw CredentialError.busy }
        if reference.purpose == .neteaseMusic { try rotateMusicEpoch(reference) }
        try repository.remove(reference); return .init(localRemoved: true)
    }
}
