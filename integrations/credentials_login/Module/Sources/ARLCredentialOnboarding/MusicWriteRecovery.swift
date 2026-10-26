import Foundation

/// Audit and attempts for the SAME original UUID. No token, extra permission,
/// replacement request ID, or change to the original pending record.
struct MusicWriteRecoveryRecord: Codable, Sendable {
    enum Reason: String, Codable, Sendable { case notDispatched, userRequestedOnce, duplicateSafeAppendOnce }
    struct AppendDecision: Codable, Equatable, Sendable {
        // Public official contract: duplicate addition returns code 200/data [].
        // https://developer.music.163.com/st/developer/document?docId=81deeef0f74147dba249531b5e08042d
        static let currentContract = "netease-batch-like-duplicate-20260414"
        let contract: String
        let priorAttemptCount: Int
        let decidedAt: Date
    }
    let request: MusicWriteRequest
    let reference: UUID
    let epoch: UUID
    let reason: Reason
    let decidedAt: Date
    var attempts: [MusicWriteRecord] = []
    var reconciled: MusicWriteResult?
    var appendDecision: AppendDecision?
    // A proved local non-dispatch does not spend the one authorized effect.
    // Only a later explicit call may reserve again; unknown/submitted never do.
    var mayReserve: Bool {
        appendDecision == nil && reason != .duplicateSafeAppendOnce &&
        reconciled == nil && attempts.count < 16 && (attempts.isEmpty ||
            attempts.last?.effectDisposition == .notDispatched)
    }
    // Only the explicitly named recovery entry may use this. The decision and
    // its one reservation are committed together; even not-dispatched spends it.
    var mayReserveAppendOnce: Bool {
        request.intent == .appendSong && appendDecision == nil && reconciled == nil &&
        attempts.last?.result == nil && attempts.count < 16
    }
    func validate(original: MusicWriteRecord) throws {
        guard request == original.request, reference == original.reference, epoch == original.epoch,
              original.result == nil,
              original.returnedPlaylistID == nil || request.intent == .appendSong && original.returnedPlaylistID == request.playlistID,
              reason != .notDispatched || original.effectDisposition == .notDispatched,
              reason != .userRequestedOnce || request.intent == .createPlaylist && original.effectDisposition != .submitted,
              reason != .duplicateSafeAppendOnce || request.intent == .appendSong,
              decidedAt.timeIntervalSince1970.isFinite, attempts.count <= 16
        else { throw CredentialError.uncertainLocalState }
        if let decision = appendDecision {
            guard request.intent == .appendSong, decision.contract == AppendDecision.currentContract,
                  decision.decidedAt.timeIntervalSince1970.isFinite,
                  (0..<16).contains(decision.priorAttemptCount),
                  attempts.count == decision.priorAttemptCount + 1,
                  attempts.prefix(decision.priorAttemptCount).allSatisfy({ $0.result == nil })
            else { throw CredentialError.uncertainLocalState }
        } else if reason == .duplicateSafeAppendOnce, !attempts.isEmpty {
            throw CredentialError.uncertainLocalState
        }
        for (index, attempt) in attempts.enumerated() {
            guard attempt.request == request, !attempt.request.reconcileOnly,
                  attempt.reference == reference, attempt.epoch == epoch,
                  attempt.baseline.count <= 500, Set(attempt.baseline).count == attempt.baseline.count,
                  attempt.baseline.allSatisfy(MusicReadProtocol.validID),
                  attempt.returnedPlaylistID.map(MusicReadProtocol.validID) ?? true,
                  attempt.effectDisposition != .notDispatched || attempt.returnedPlaylistID == nil && attempt.result == nil,
                  index == attempts.count - 1 || attempt.effectDisposition == .notDispatched ||
                    index == (appendDecision?.priorAttemptCount ?? 0) - 1
            else { throw CredentialError.uncertainLocalState }
            guard !request.isSongListUpdate || attempt.baselineSongIDs.map({ $0.allSatisfy(MusicReadProtocol.validID) && Set($0).count == $0.count }) == true else { throw CredentialError.uncertainLocalState }
            try validateResult(attempt.result)
        }
        try validateResult(reconciled)
    }
    private func validateResult(_ value: MusicWriteResult?) throws {
        guard let value else { return }
        guard value.readbackVerified, value.requestID == request.requestID,
              value.songID == request.songID, value.playlistID.map(MusicReadProtocol.validID) == true
        else { throw CredentialError.uncertainLocalState }
    }
    func preserves(_ old: Self) -> Bool {
        guard request == old.request, reference == old.reference, epoch == old.epoch,
              reason == old.reason, decidedAt == old.decidedAt,
              attempts.count >= old.attempts.count, attempts.count <= old.attempts.count + 1,
              old.reconciled == nil || reconciled == old.reconciled,
              old.appendDecision == nil || appendDecision == old.appendDecision else { return false }
        let newAppendDecision = old.appendDecision == nil && appendDecision != nil
        if newAppendDecision {
            guard old.mayReserveAppendOnce,
                  appendDecision?.priorAttemptCount == old.attempts.count,
                  attempts.count == old.attempts.count + 1 else { return false }
        } else if attempts.count > old.attempts.count, !old.mayReserve { return false }
        for (index, prior) in old.attempts.enumerated() {
            let next = attempts[index]
            if newAppendDecision, next != prior { return false }
            guard next.request == prior.request, next.reference == prior.reference, next.epoch == prior.epoch,
                  next.baseline == prior.baseline,
                  prior.effectDisposition == nil || next.effectDisposition == prior.effectDisposition,
                  prior.returnedPlaylistID == nil || next.returnedPlaylistID == prior.returnedPlaylistID,
                  prior.result == nil || next.result == prior.result else { return false }
        }
        return true
    }
}
struct MusicWriteRecoveryLedger: Codable, Sendable {
    var schema = 1
    var records: [String: MusicWriteRecoveryRecord] = [:]
    func validate(originals: MusicWriteLedger) throws {
        guard [1, 2].contains(schema), records.count <= 512,
              schema == 2 || records.values.allSatisfy({ $0.appendDecision == nil && $0.reason != .duplicateSafeAppendOnce })
        else { throw CredentialError.uncertainLocalState }
        for (key, record) in records {
            guard key == record.request.requestID.uuidString, let original = originals.records[key]
            else { throw CredentialError.uncertainLocalState }
            try record.validate(original: original)
        }
    }
}
public struct MusicWriteRecoveryStatus: Encodable, Sendable {
    public let attemptCount: Int
    public let effectDisposition: MusicEffectDisposition?
    public let reason: String
    public let appendRecoveryReserved: Bool
    public let appendRecoveryPriorAttemptCount: Int?
    public let appendRecoveryContract: String?
    enum CodingKeys: String, CodingKey {
        case attemptCount = "attempt_count", effectDisposition = "effect_disposition", reason
        case appendRecoveryReserved = "append_recovery_reserved"
        case appendRecoveryPriorAttemptCount = "append_recovery_prior_attempt_count"
        case appendRecoveryContract = "append_recovery_contract"
    }
    init(_ record: MusicWriteRecoveryRecord) {
        attemptCount = record.attempts.count; effectDisposition = record.attempts.last?.effectDisposition
        reason = record.reason.rawValue
        appendRecoveryReserved = record.appendDecision != nil
        appendRecoveryPriorAttemptCount = record.appendDecision?.priorAttemptCount
        appendRecoveryContract = record.appendDecision?.contract
    }
}
