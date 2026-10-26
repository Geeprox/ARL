import Foundation
import Security

/// Exact new purpose slots in the positively verified local login Keychain.
/// No search-list fallback, import, automatic overwrite, repair or uncertain-operation retry.
final class LoginKeychainRepository: CredentialRepository, @unchecked Sendable {
    private struct VerifiedItem { let native: Any; let label: String }
    private let gate: any DeploymentGate
    private let calls: any LoginItemCalls
    private let environment: any LoginEnvironment
    private let receipts: any LoginReceiptStore
    private let identity: String
    private let itemScope: LoginItemScope
    init(gate: any DeploymentGate, calls: any LoginItemCalls, environment: any LoginEnvironment,
         receipts: any LoginReceiptStore, identity: String, itemScope: LoginItemScope = .original) {
        self.gate = gate; self.calls = calls; self.environment = environment; self.receipts = receipts; self.identity = identity
        self.itemScope = itemScope
    }
    private func run<T>(_ body: (LoginSession) throws -> T) throws -> T {
        try gate.verify()
        return try receipts.withLock { try environment.withSession(body) }
    }
    private func encode(_ metadata: StoredMetadata) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(metadata)
    }
    private func status(_ value: OSStatus, operation: CredentialStorageOperation = .metadataRead) throws {
        if value == errSecDuplicateItem { throw CredentialError.alreadyConfigured }
        guard value == errSecSuccess else { throw CredentialStorageFailure(operation: operation, status: value) }
    }
    func query(_ purpose: CredentialPurpose, session: LoginSession, item: Any? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: itemScope.service(purpose), kSecAttrAccount as String: itemScope.account,
            kSecMatchSearchList as String: [session.target], kSecUseDataProtectionKeychain as String: false,
            kSecAttrSynchronizable as String: false]
        if let item { q[kSecValueRef as String] = item }; return q
    }
    private func presence(_ purpose: CredentialPurpose, session: LoginSession) throws -> Bool {
        var q = query(purpose, session: session)
        q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = false; q[kSecReturnRef as String] = false; q[kSecReturnPersistentRef as String] = false
        let (s, value) = calls.copy(q)
        if s == errSecItemNotFound { return false }; try status(s)
        guard value is [String: Any] else { throw CredentialError.uncertainLocalState }; return true
    }
    private func load(_ purpose: CredentialPurpose, session: LoginSession) throws -> LoginCreationReceipt? {
        guard let record = try receipts.load(purpose) else {
            guard try !presence(purpose, session: session) else { throw CredentialError.uncertainLocalState }; return nil
        }
        guard record.schema == 1, record.identity == identity, record.purpose == purpose, record.loginPath == session.path,
              record.metadata.schema == 1, record.metadata.reference.purpose == purpose, record.metadata.isConsistent
        else { throw CredentialError.uncertainLocalState }
        if record.phase == .removed {
            guard try !presence(purpose, session: session) else { throw CredentialError.uncertainLocalState }; return nil
        }
        guard record.phase == .owned,
              canonical(record.baselineACL) == canonical(try environment.prepareAccess().1)
        else { throw CredentialError.uncertainLocalState }; return record
    }
    private func canonical(_ entries: [LoginACLSnapshot]) -> [LoginACLSnapshot] {
        entries.sorted { $0.authorizations.map(\.rawValue).sorted().joined(separator: ",") < $1.authorizations.map(\.rawValue).sorted().joined(separator: ",") }
    }
    private func exact(_ record: LoginCreationReceipt, session: LoginSession, item: VerifiedItem) throws -> [String: Any] {
        var q = query(record.purpose, session: session, item: item.native)
        q[kSecAttrGeneric as String] = try encode(record.metadata); q[kSecAttrComment as String] = record.nonce.uuidString
        q[kSecAttrLabel as String] = item.label; return q
    }
    @discardableResult
    private func verify(_ record: LoginCreationReceipt, session: LoginSession, item: Any) throws -> VerifiedItem {
        guard let persistent = record.persistentReference,
              try environment.persistentReference(item) == persistent,
              try environment.parentPath(item) == session.path
        else { throw CredentialError.uncertainLocalState }
        // A persistent-reference result can be lazy: load nonsecret metadata and
        // its item before inspecting access. Changed metadata must not look absent.
        var q = query(record.purpose, session: session, item: item)
        q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = false; q[kSecReturnRef as String] = true; q[kSecReturnPersistentRef as String] = false
        let (s, value) = calls.copy(q); try status(s)
        guard let fields = value as? [String: Any],
              fields[kSecAttrService as String] as? String == itemScope.service(record.purpose),
              fields[kSecAttrAccount as String] as? String == itemScope.account,
              let label = fields[kSecAttrLabel as String] as? String, record.purpose.acceptsStoredLabel(label),
              fields[kSecAttrComment as String] as? String == record.nonce.uuidString,
              fields[kSecAttrGeneric as String] as? Data == (try encode(record.metadata)),
              let loadedItem = fields[kSecValueRef as String],
              try environment.persistentReference(loadedItem) == persistent,
              try environment.parentPath(loadedItem) == session.path,
              canonical(try environment.inspectACL(loadedItem)) == canonical(record.baselineACL)
        else { throw CredentialError.uncertainLocalState }
        return .init(native: loadedItem, label: label)
    }
    private func owned(_ ref: CredentialReference, session: LoginSession) throws -> (LoginCreationReceipt, VerifiedItem) {
        guard let record = try load(ref.purpose, session: session) else { throw CredentialError.missing }
        guard record.metadata.reference == ref else { throw CredentialError.staleReference }
        guard let persistent = record.persistentReference else { throw CredentialError.uncertainLocalState }
        let item = try environment.resolve(persistent)
        return (record, try verify(record, session: session, item: item))
    }
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? {
        try run { session in
            guard let record = try load(purpose, session: session) else { return nil }
            guard let persistent = record.persistentReference else { throw CredentialError.uncertainLocalState }
            try verify(record, session: session, item: environment.resolve(persistent)); return record.metadata
        }
    }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata {
        defer { input.clear() }; guard input.purpose == purpose else { throw CredentialError.wrongPurpose }
        return try run { session in
            guard try load(purpose, session: session) == nil else { throw CredentialError.alreadyConfigured }
            return try createNew(input, purpose: purpose, session: session)
        }
    }
    /// Called only by an explicit user submission. Reconcile the exact intent
    /// using metadata first; never retry an existing write or replace its value.
    func createRecovering(_ input: CredentialInput, purpose: CredentialPurpose) throws -> CredentialCreation {
        defer { input.clear() }; guard input.purpose == purpose else { throw CredentialError.wrongPurpose }
        return try run { session in
            if var record = try receipts.load(purpose), record.phase == .intent {
                guard record.schema == 1, record.identity == identity, record.purpose == purpose,
                      record.loginPath == session.path, record.persistentReference == nil,
                      record.metadata.schema == 1, record.metadata.reference.purpose == purpose,
                      record.metadata.isConsistent, record.metadata.state == .savedUnverified,
                      canonical(record.baselineACL) == canonical(try environment.prepareAccess().1)
                else { throw CredentialError.uncertainLocalState }
                var q = query(purpose, session: session)
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                q[kSecReturnAttributes as String] = true; q[kSecReturnRef as String] = true
                q[kSecReturnData as String] = false; q[kSecReturnPersistentRef as String] = false
                let (s, value) = calls.copy(q)
                if s == errSecItemNotFound {
                    // Positive absence under the receipt lock permits a fresh
                    // intent. Native uniqueness still rejects a competing add.
                    return .init(metadata: try createNew(input, purpose: purpose, session: session), recoveredExisting: false)
                }
                try status(s, operation: .creationRecovery)
                guard let fields = value as? [String: Any], let item = fields[kSecValueRef as String] else { throw CredentialError.uncertainLocalState }
                record.persistentReference = try environment.persistentReference(item)
                // Exact nonce, metadata, path, persistent reference and all
                // application ACL entries must match before recording ownership.
                try verify(record, session: session, item: item)
                record.phase = .owned
                try receipts.write(record)
                return .init(metadata: record.metadata, recoveredExisting: true)
            }
            guard try load(purpose, session: session) == nil else { throw CredentialError.alreadyConfigured }
            return .init(metadata: try createNew(input, purpose: purpose, session: session), recoveredExisting: false)
        }
    }
    private func createNew(_ input: CredentialInput, purpose: CredentialPurpose, session: LoginSession, verified: StoredMetadata? = nil) throws -> StoredMetadata {
            let (access, baseline) = try environment.prepareAccess()
            // Validated by the preparation policy. Persist exactly this ACL; never bless a normalized/wider layout.
            guard baseline.count == 3 else { throw CredentialError.uncertainLocalState }
            let metadata = verified ?? StoredMetadata(reference: .init(purpose: purpose))
            var record = LoginCreationReceipt(schema: 1, identity: identity, purpose: purpose, loginPath: session.path,
                nonce: UUID(), phase: .intent, persistentReference: nil, metadata: metadata, baselineACL: baseline)
            try receipts.write(record) // Durable before dispatch; failure or interruption cannot trigger an automatic retry.
            var fields = query(purpose, session: session)
            fields.removeValue(forKey: kSecMatchSearchList as String)
            fields[kSecUseKeychain as String] = session.target; fields[kSecAttrAccess as String] = access
            fields[kSecAttrLabel as String] = purpose.storageLabel; fields[kSecAttrComment as String] = record.nonce.uuidString
            fields[kSecAttrGeneric as String] = try encode(metadata); fields[kSecValueData as String] = try input.copyBytes(for: purpose)
            fields[kSecReturnRef as String] = true
            let (s, item) = calls.addReturning(fields); try status(s, operation: .itemCreate)
            guard let item else { throw CredentialError.uncertainLocalState }
            record.persistentReference = try environment.persistentReference(item)
            try verify(record, session: session, item: item)
            record.phase = .owned; try receipts.write(record); return metadata
    }
    private func update(_ record: LoginCreationReceipt, session: LoginSession, item: VerifiedItem,
                        metadata: StoredMetadata, secret: Data? = nil) throws -> StoredMetadata {
        var pending = record; pending.phase = .pendingUpdate
        if record.purpose != .neteaseMusic { pending.pendingMetadata = metadata }
        try receipts.write(pending)
        var changes: [String: Any] = [kSecAttrGeneric as String: try encode(metadata)]
        if let secret { changes[kSecValueData as String] = secret }
        try status(calls.update(try exact(record, session: session, item: item), changes), operation: .itemUpdate)
        var updated = record; updated.metadata = metadata; updated.pendingMetadata = nil
        try verify(updated, session: session, item: item.native); try receipts.write(updated); return metadata
    }
    /// A single exact-item native update commits the new value and its evidence.
    /// The old value remains selected until bounded validation has succeeded.
    func installVerifiedTravel(_ input: CredentialInput, result: ConnectionTestResult, expected: StoredMetadata?) throws -> StoredMetadata {
        defer { input.clear() }
        guard TravelCredentialEvidence.accepts(result, purpose: input.purpose),
              expected == nil || expected?.reference.purpose == input.purpose else { throw CredentialError.wrongPurpose }
        return try run { session in
            if let expected {
                let (record, item) = try owned(expected.reference, session: session)
                guard record.metadata == expected else { throw CredentialError.staleReference }
                let metadata = StoredMetadata(reference: expected.reference, state: .verified, lastTest: result)
                return try update(record, session: session, item: item, metadata: metadata, secret: input.copyBytes(for: input.purpose))
            }
            // Positive absence and native uniqueness protect a first migration.
            // An unowned or interrupted transaction is never overwritten here.
            if let pending = try receipts.load(input.purpose), pending.phase == .intent {
                guard pending.schema == 1, pending.identity == identity, pending.purpose == input.purpose,
                      pending.loginPath == session.path, pending.persistentReference == nil,
                      pending.metadata.reference.purpose == input.purpose, pending.metadata.isConsistent,
                      canonical(pending.baselineACL) == canonical(try environment.prepareAccess().1),
                      try !presence(input.purpose, session: session) else { throw CredentialError.uncertainLocalState }
            } else {
                guard try load(input.purpose, session: session) == nil else { throw CredentialError.alreadyConfigured }
            }
            let metadata = StoredMetadata(reference: .init(purpose: input.purpose), state: .verified, lastTest: result)
            return try createNew(input, purpose: input.purpose, session: session, verified: metadata)
        }
    }
    /// Explicit recovery reads only exact owned-item metadata. It never imports,
    /// retries a native write, reads a value, expands ACLs, or searches other slots.
    func recoverTravelMetadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? {
        guard purpose != .neteaseMusic else { throw CredentialError.wrongPurpose }
        return try run { session in
            guard var record = try receipts.load(purpose) else {
                guard try !presence(purpose, session: session) else { throw CredentialError.uncertainLocalState }; return nil
            }
            guard record.schema == 1, record.identity == identity, record.purpose == purpose,
                  record.loginPath == session.path, record.metadata.schema == 1,
                  record.metadata.reference.purpose == purpose, record.metadata.isConsistent,
                  canonical(record.baselineACL) == canonical(try environment.prepareAccess().1)
            else { throw CredentialError.uncertainLocalState }
            if record.phase == .intent {
                guard record.persistentReference == nil else { throw CredentialError.uncertainLocalState }
                var q = query(purpose, session: session)
                q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecReturnAttributes as String] = true
                q[kSecReturnRef as String] = true; q[kSecReturnData as String] = false; q[kSecReturnPersistentRef as String] = false
                let (s, value) = calls.copy(q)
                if s == errSecItemNotFound { return nil }
                try status(s, operation: .creationRecovery)
                guard let fields = value as? [String: Any], let item = fields[kSecValueRef as String] else { throw CredentialError.uncertainLocalState }
                record.persistentReference = try environment.persistentReference(item)
                try verify(record, session: session, item: item)
                record.phase = .owned; try receipts.write(record); return record.metadata
            }
            if record.phase == .pendingUpdate {
                guard let persistent = record.persistentReference, let target = record.pendingMetadata,
                      target.reference == record.metadata.reference, target.isConsistent
                else { throw CredentialError.uncertainLocalState }
                let item = try environment.resolve(persistent)
                var completed = record; completed.metadata = target; completed.phase = .owned; completed.pendingMetadata = nil
                do { try verify(completed, session: session, item: item) }
                catch {
                    // A rejected atomic update may still match the exact old
                    // metadata. Anything else remains uncertain and untouched.
                    completed.metadata = record.metadata
                    try verify(completed, session: session, item: item)
                }
                try receipts.write(completed); return completed.metadata
            }
            guard let loaded = try load(purpose, session: session) else { return nil }
            guard let persistent = loaded.persistentReference else { throw CredentialError.uncertainLocalState }
            try verify(loaded, session: session, item: environment.resolve(persistent)); return loaded.metadata
        }
    }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata {
        defer { input.clear() }; guard input.purpose == ref.purpose else { throw CredentialError.wrongPurpose }
        return try run { session in
            let (record, item) = try owned(ref, session: session)
            return try update(record, session: session, item: item, metadata: .init(reference: ref), secret: input.copyBytes(for: ref.purpose))
        }
    }
    func commitLease(_ ref: CredentialReference, input: CredentialInput, result: ConnectionTestResult?, expectedGeneration: UUID) throws -> StoredMetadata {
        defer { input.clear() }
        guard ref.purpose == .neteaseMusic, input.purpose == ref.purpose else { throw CredentialError.wrongPurpose }
        return try run { session in
            let (record, item) = try owned(ref, session: session)
            guard record.metadata.generation == expectedGeneration else { throw CredentialError.staleReference }
            let metadata = StoredMetadata(reference: ref, state: result?.state ?? .savedUnverified, lastTest: result)
            guard metadata.isConsistent else { throw CredentialError.uncertainLocalState }
            return try update(record, session: session, item: item, metadata: metadata, secret: input.copyBytes(for: ref.purpose))
        }
    }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) {
        try run { session in
            let (record, item) = try owned(ref, session: session)
            var q = try exact(record, session: session, item: item); q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecReturnData as String] = true; q[kSecReturnAttributes as String] = false
            q[kSecReturnRef as String] = false; q[kSecReturnPersistentRef as String] = false
            let (s, value) = calls.copy(q); try status(s, operation: .credentialRead)
            guard let data = value as? Data, data.count <= ref.purpose.maximumCredentialBytes else { throw CredentialError.uncertainLocalState }
            // Detect observable concurrent changes before exporting the internal ephemeral lease.
            try verify(record, session: session, item: item.native)
            return (record.metadata, try CredentialInput(purpose: ref.purpose, data: data))
        }
    }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata {
        if ref.purpose == .fliggyTravelReadOnly, result.state == .verified, result.evidence != .flyaiDifferentialReadOnlyResponse { throw CredentialError.uncertainLocalState }
        return try run { session in
            let (record, item) = try owned(ref, session: session)
            guard record.metadata.generation == expectedGeneration else { throw CredentialError.staleReference }
            let updated = StoredMetadata(reference: ref, state: result.state, lastTest: result)
            guard updated.isConsistent else { throw CredentialError.uncertainLocalState }
            return try update(record, session: session, item: item, metadata: updated)
        }
    }
    func remove(_ ref: CredentialReference) throws {
        try run { session in
            guard try load(ref.purpose, session: session) != nil else { return }
            var (record, item) = try owned(ref, session: session)
            let q = try exact(record, session: session, item: item)
            record.phase = .pendingRemoval; try receipts.write(record)
            try status(calls.delete(q), operation: .itemRemove)
            guard try !presence(ref.purpose, session: session) else { throw CredentialError.uncertainLocalState }
            record.phase = .removed; try receipts.write(record)
        }
    }
}
