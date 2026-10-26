import Foundation
import Security

// Same module as the frozen production SDK. Every Security/environment effect
// is injected; this tests the actual LoginKeychainRepository state machine.
private enum TestFailure: Error { case check(String), receipt }
private struct TestGate: DeploymentGate { func verify() throws {} }
private struct TestItem { let id: UUID }
private struct TestTarget { let id = "SYNTHETIC-LOGIN-TARGET" }
private struct TestAccess { let id = "SYNTHETIC-ARL-ONLY-ACCESS" }
private final class TestReceipts: LoginReceiptStore, @unchecked Sendable {
    private let lock = NSLock()
    var stored: LoginCreationReceipt?
    var failOwnedWriteOnce = false
    func withLock<T>(_ body: () throws -> T) throws -> T { try lock.withLock(body) }
    func load(_ purpose: CredentialPurpose) throws -> LoginCreationReceipt? { stored }
    func write(_ receipt: LoginCreationReceipt) throws {
        if failOwnedWriteOnce && receipt.phase == .owned { failOwnedWriteOnce = false; throw TestFailure.receipt }
        stored = receipt
    }
}
private final class TestLogin: LoginItemCalls, LoginEnvironment, @unchecked Sendable {
    enum Fault { case none, addRejected, addCommittedReplyLost, updateRejected, updateCommittedReplyLost }
    private struct Row {
        let item: TestItem
        var fields: [String: Any]
        var secret: Data
        var acl: [LoginACLSnapshot]
    }
    private let purpose: CredentialPurpose
    init(purpose: CredentialPurpose = .amapMapsWeather) { self.purpose = purpose }
    private let lock = NSLock()
    private var row: Row?
    private var fault: Fault = .none
    private var additions = 0, updates = 0, secretReads = 0
    private var valueReadLabel: String?
    var storedLabel: String? { lock.withLock { row?.fields[kSecAttrLabel as String] as? String } }
    var lastValueReadLabel: String? { lock.withLock { valueReadLabel } }
    func setStoredLabel(_ value: String) { lock.withLock { row?.fields[kSecAttrLabel as String] = value } }
    func corruptNonce() { lock.withLock { row?.fields[kSecAttrComment as String] = "SYNTHETIC-WRONG-NONCE" } }
    static let loginPath = "/SYNTHETIC-HOME/Library/Keychains/login.keychain-db"
    private var baseline: [LoginACLSnapshot] {
        let pin = Data("SYNTHETIC-ARL-APPLICATION-PIN".utf8)
        return [.init(authorizations: [.changeACL], applicationPins: [], promptFlags: 0),
                .init(authorizations: [.encrypt], applicationPins: [pin], promptFlags: 0),
                .init(authorizations: LoginACLPolicy.sensitive, applicationPins: [pin], promptFlags: 0)]
    }
    func setFault(_ next: Fault) { lock.withLock { fault = next } }
    var addCount: Int { lock.withLock { additions } }
    var updateCount: Int { lock.withLock { updates } }
    var readCount: Int { lock.withLock { secretReads } }
    var originalValue: Bool { lock.withLock { row?.secret == Data("SYNTHETIC-ORIGINAL-KEY".utf8) } }
    func corruptMetadata() { lock.withLock { row?.fields[kSecAttrGeneric as String] = Data("SYNTHETIC-CORRUPT-METADATA".utf8) } }
    func corruptACL() { lock.withLock { row?.acl = [] } }
    private func valid(_ q: [String: Any], adding: Bool = false) -> Bool {
        guard q[kSecClass as String] as? String == kSecClassGenericPassword as String,
              q[kSecAttrService as String] as? String == LoginItemScope.teamReentryV1.service(purpose),
              q[kSecAttrAccount as String] as? String == LoginItemScope.teamReentryV1.account,
              q[kSecUseDataProtectionKeychain as String] as? Bool == false,
              q[kSecAttrSynchronizable as String] as? Bool == false else { return false }
        if adding { return q[kSecUseKeychain as String] is TestTarget && q[kSecAttrAccess as String] is TestAccess && q[kSecMatchSearchList as String] == nil }
        return (q[kSecMatchSearchList as String] as? [TestTarget])?.count == 1 && q[kSecUseKeychain as String] == nil
    }
    private func matches(_ value: Row, _ q: [String: Any]) -> Bool {
        if let item = q[kSecValueRef as String] as? TestItem, item.id != value.item.id { return false }
        for key in [kSecAttrService as String, kSecAttrAccount as String, kSecAttrLabel as String, kSecAttrComment as String] {
            if let text = q[key] as? String, value.fields[key] as? String != text { return false }
        }
        if let generic = q[kSecAttrGeneric as String] as? Data, value.fields[kSecAttrGeneric as String] as? Data != generic { return false }
        return true
    }
    func copy(_ q: [String: Any]) -> (OSStatus, Any?) {
        lock.withLock {
            guard valid(q) else { return (errSecParam, nil) }
            guard let row, matches(row, q) else { return (errSecItemNotFound, nil) }
            if q[kSecReturnData as String] as? Bool == true { secretReads += 1; valueReadLabel = q[kSecAttrLabel as String] as? String; return (errSecSuccess, row.secret) }
            guard q[kSecReturnData as String] as? Bool == false, q[kSecReturnAttributes as String] as? Bool == true else { return (errSecParam, nil) }
            var fields = row.fields
            if q[kSecReturnRef as String] as? Bool == true { fields[kSecValueRef as String] = row.item }
            return (errSecSuccess, fields)
        }
    }
    func add(_ q: [String: Any]) -> OSStatus { errSecParam }
    func addReturning(_ q: [String: Any]) -> (OSStatus, Any?) {
        lock.withLock {
            guard valid(q, adding: true), let secret = q[kSecValueData as String] as? Data else { return (errSecParam, nil) }
            additions += 1
            if row != nil { return (errSecDuplicateItem, nil) }
            if fault == .addRejected { fault = .none; return (errSecNotAvailable, nil) }
            let item = TestItem(id: UUID())
            let keys = [kSecAttrService as String, kSecAttrAccount as String, kSecAttrLabel as String, kSecAttrComment as String, kSecAttrGeneric as String]
            row = .init(item: item, fields: Dictionary(uniqueKeysWithValues: keys.compactMap { key in q[key].map { (key, $0) } }), secret: secret, acl: baseline)
            if fault == .addCommittedReplyLost { fault = .none; return (errSecInternalComponent, nil) }
            return (errSecSuccess, item)
        }
    }
    func update(_ q: [String: Any], _ changes: [String: Any]) -> OSStatus {
        lock.withLock {
            guard valid(q), q[kSecValueRef as String] is TestItem, q[kSecAttrGeneric as String] is Data,
                  Set(changes.keys).isSubset(of: [kSecAttrGeneric as String, kSecValueData as String]),
                  let old = row, matches(old, q), let generic = changes[kSecAttrGeneric as String] as? Data else { return errSecParam }
            updates += 1
            if fault == .updateRejected { fault = .none; return errSecNotAvailable }
            row?.fields[kSecAttrGeneric as String] = generic
            if let bytes = changes[kSecValueData as String] as? Data { row?.secret = bytes }
            if fault == .updateCommittedReplyLost { fault = .none; return errSecInternalComponent }
            return errSecSuccess
        }
    }
    func delete(_ q: [String: Any]) -> OSStatus { errSecParam }
    func withSession<T>(_ body: (LoginSession) throws -> T) throws -> T { try body(.init(target: TestTarget(), path: Self.loginPath)) }
    func prepareAccess() throws -> (Any, [LoginACLSnapshot]) { (TestAccess(), baseline) }
    func inspectACL(_ item: Any) throws -> [LoginACLSnapshot] {
        try lock.withLock { guard let row, (item as? TestItem)?.id == row.item.id else { throw CredentialError.uncertainLocalState }; return row.acl }
    }
    func persistentReference(_ item: Any) throws -> Data {
        guard let item = item as? TestItem else { throw CredentialError.uncertainLocalState }; return Data(item.id.uuidString.utf8)
    }
    func resolve(_ reference: Data) throws -> Any {
        try lock.withLock { guard let row, Data(row.item.id.uuidString.utf8) == reference else { throw CredentialError.uncertainLocalState }; return row.item }
    }
    func parentPath(_ item: Any) throws -> String { Self.loginPath }
}
private func repository(_ calls: TestLogin, _ receipts: TestReceipts) -> LoginKeychainRepository {
    .init(gate: TestGate(), calls: calls, environment: calls, receipts: receipts, identity: "SYNTHETIC-ARL-TEAM-IDENTITY", itemScope: .teamReentryV1)
}
private func originalInput() throws -> CredentialInput { try .init(purpose: .amapMapsWeather, value: "SYNTHETIC-ORIGINAL-KEY") }
private func candidateInput() throws -> CredentialInput { try .init(purpose: .amapMapsWeather, value: "SYNTHETIC-CANDIDATE-KEY") }
private func evidence() -> ConnectionTestResult { .init(.verified, evidence: .amapWeatherResponse) }
@main enum TravelLoginRecoveryTests {
    static func main() throws {
        var checks: [String] = []
        func check(_ pass: Bool, _ name: String) throws { guard pass else { throw TestFailure.check(name) }; checks.append(name) }
        // A display-name change cannot invalidate an already-owned Keychain item.
        for purpose: CredentialPurpose in [.amapMapsWeather, .fliggyTravelReadOnly] {
            let originalLabel = purpose == .amapMapsWeather ? "ARL · 高德地图与天气" : "ARL · 飞猪旅行查询（FlyAI）"
            let shortLabel = purpose == .amapMapsWeather ? "ARL · 高德地图" : "ARL · 飞猪旅行"
            let stableLabel = purpose == .amapMapsWeather ? "ARL · amap.maps-weather" : "ARL · fliggy.travel-readonly"
            for label in [originalLabel, shortLabel, stableLabel] {
                let calls = TestLogin(purpose: purpose), receipts = TestReceipts(), repo = repository(calls, receipts)
                let result = ConnectionTestResult(.verified, evidence: purpose == .amapMapsWeather ? .amapWeatherResponse : .flyaiDifferentialReadOnlyResponse)
                let input = try CredentialInput(purpose: purpose, value: "SYNTHETIC-ORIGINAL-KEY")
                let original = try repo.installVerifiedTravel(input, result: result, expected: nil)
                try check(calls.storedLabel == stableLabel, "new_item_label_uses_immutable_purpose")
                calls.setStoredLabel(label) // Existing native item from a known released label contract.
                let found = try repo.metadata(purpose)
                let recovered = try repo.recoverTravelMetadata(purpose)
                try check(found == original && recovered == original && calls.readCount == 0 && calls.addCount == 1 && calls.updateCount == 0,
                          "known_label_metadata_no_migration_" + purpose.rawValue)
                let lease = try repo.lease(original.reference); lease.secret.clear()
                try check(calls.lastValueReadLabel == label && calls.readCount == 1, "lease_binds_verified_actual_label")
                _ = try repo.record(original.reference, result: result, expectedGeneration: original.generation)
                try check(calls.storedLabel == label && calls.addCount == 1 && calls.updateCount == 1 && calls.originalValue,
                          "record_preserves_existing_label_and_value")
            }
        }
        for damage in ["unknown_label", "wrong_purpose_label", "nonce", "metadata", "acl"] {
            let calls = TestLogin(), receipts = TestReceipts(), repo = repository(calls, receipts)
            let old = try repo.installVerifiedTravel(originalInput(), result: evidence(), expected: nil)
            switch damage {
            case "unknown_label": calls.setStoredLabel("ARL · unrelated")
            case "wrong_purpose_label": calls.setStoredLabel("ARL · 飞猪旅行查询（FlyAI）")
            case "nonce": calls.corruptNonce()
            case "metadata": calls.corruptMetadata()
            default: calls.corruptACL()
            }
            var rejected = false
            do { _ = try repo.lease(old.reference) } catch { rejected = true }
            try check(rejected && calls.readCount == 0 && calls.updateCount == 0 && calls.addCount == 1,
                      "label_compatibility_never_bypasses_" + damage)
        }
        // Add happened, response lost: recover exact intent without a second add.
        for lostReceipt in [false, true] {
            let calls = TestLogin(), receipts = TestReceipts(), repo = repository(calls, receipts)
            if lostReceipt { receipts.failOwnedWriteOnce = true } else { calls.setFault(.addCommittedReplyLost) }
            var failed = false
            do { _ = try repo.installVerifiedTravel(originalInput(), result: evidence(), expected: nil) } catch { failed = true }
            try check(failed && receipts.stored?.phase == .intent, "create_unconfirmed_" + String(lostReceipt))
            let recovered = try repository(calls, receipts).recoverTravelMetadata(.amapMapsWeather)
            try check(recovered?.state == .verified && receipts.stored?.phase == .owned && calls.addCount == 1 && calls.readCount == 0,
                      "recover_exact_create_without_value_read_or_replay_" + String(lostReceipt))
            _ = try repository(calls, receipts).recoverTravelMetadata(.amapMapsWeather)
            try check(calls.addCount == 1 && calls.readCount == 0, "repeat_recovery_is_metadata_only_" + String(lostReceipt))
        }
        // Failed native update retains old value; successful-but-lost reply can
        // be distinguished by exact target metadata, not by reading the secret.
        for committed in [false, true] {
            let calls = TestLogin(), receipts = TestReceipts(), repo = repository(calls, receipts)
            let original = try repo.installVerifiedTravel(originalInput(), result: evidence(), expected: nil)
            calls.setFault(committed ? .updateCommittedReplyLost : .updateRejected)
            var failed = false
            do { _ = try repo.installVerifiedTravel(candidateInput(), result: evidence(), expected: original) } catch { failed = true }
            try check(failed && receipts.stored?.phase == .pendingUpdate, "update_unconfirmed_" + String(committed))
            let recovered = try repository(calls, receipts).recoverTravelMetadata(.amapMapsWeather)
            try check(recovered?.reference == original.reference && receipts.stored?.phase == .owned && calls.updateCount == 1 && calls.readCount == 0,
                      "recover_update_no_secret_read_or_replay_" + String(committed))
            try check(committed ? recovered?.generation != original.generation && !calls.originalValue : recovered == original && calls.originalValue,
                      "recover_exact_old_or_committed_target_" + String(committed))
        }
        // Intent with positive absence remains absence; a later explicit action
        // may start a new verified transaction, never an automatic effect retry.
        let absentCalls = TestLogin(), absentReceipts = TestReceipts(), absent = repository(absentCalls, absentReceipts)
        absentCalls.setFault(.addRejected)
        do { _ = try absent.installVerifiedTravel(originalInput(), result: evidence(), expected: nil) } catch {}
        try check(try absent.recoverTravelMetadata(.amapMapsWeather) == nil && absentCalls.addCount == 1, "missing_intent_recovery_never_adds")
        _ = try absent.installVerifiedTravel(originalInput(), result: evidence(), expected: nil)
        try check(absentCalls.addCount == 2 && absentCalls.readCount == 0, "explicit_new_transaction_after_proved_absence")
        // Observable competing metadata or changed ACL cannot be blessed.
        for acl in [false, true] {
            let calls = TestLogin(), receipts = TestReceipts(), repo = repository(calls, receipts)
            let old = try repo.installVerifiedTravel(originalInput(), result: evidence(), expected: nil)
            calls.setFault(.updateCommittedReplyLost)
            do { _ = try repo.installVerifiedTravel(candidateInput(), result: evidence(), expected: old) } catch {}
            if acl { calls.corruptACL() } else { calls.corruptMetadata() }
            var rejected = false
            do { _ = try repo.recoverTravelMetadata(.amapMapsWeather) } catch { rejected = true }
            try check(rejected && receipts.stored?.phase == .pendingUpdate && calls.updateCount == 1 && calls.readCount == 0,
                      "unprovable_state_not_blessed_" + String(acl))
        }
        // Stale generation must be rejected by production repository itself.
        let raceCalls = TestLogin(), raceReceipts = TestReceipts(), race = repository(raceCalls, raceReceipts)
        let old = try race.installVerifiedTravel(originalInput(), result: evidence(), expected: nil)
        _ = try race.record(old.reference, result: evidence(), expectedGeneration: old.generation)
        var stale = false
        do { _ = try race.installVerifiedTravel(candidateInput(), result: evidence(), expected: old) } catch CredentialError.staleReference { stale = true }
        try check(stale && raceCalls.originalValue && raceCalls.updateCount == 1 && raceCalls.readCount == 0, "native_repository_rejects_stale_generation")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["status":"PASS", "checks":checks,
            "production_repository":true, "real_security_calls":0, "real_credentials_read":0, "provider_calls":0, "installed_writes":0], options:[.sortedKeys]), as: UTF8.self))
    }
}
