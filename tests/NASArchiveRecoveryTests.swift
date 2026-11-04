import Foundation
import Darwin

/// Exercise the production recovery policy with synthetic mount events only.
/// No credential store, actual mount or network operation is used.
@main enum NASArchiveRecoveryTests {
    static func require(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL: " + label); exit(1) }
    }
    static func main() throws {
        var checks = 0
        var events = [String]()
        let validate = { events.append("validate") }
        let credential = { events.append("credential") }
        let disconnect = { events.append("disconnect") }
        let encrypted = { events.append("encrypted") }
        let unencrypted: () throws -> Void = { events.append("unencrypted"); throw NASRuntimeFailure.accessDenied }
        let fresh = try NASArchiveMount.reuseExisting(validate: { throw NASRuntimeFailure.unavailable },
            verifyEncryption: encrypted, checkCredential: credential, disconnect: disconnect)
        require(!fresh && events.isEmpty, "fresh destination needs no disconnect"); checks += 1
        let reused = try NASArchiveMount.reuseExisting(validate: validate, verifyEncryption: encrypted,
            checkCredential: credential, disconnect: disconnect)
        require(reused && events == ["validate", "encrypted"], "encrypted mount is reused"); checks += 1
        events = []
        let reconnect = try NASArchiveMount.reuseExisting(validate: validate, verifyEncryption: unencrypted,
            checkCredential: credential, disconnect: disconnect)
        require(!reconnect && events == ["validate", "unencrypted", "credential", "validate", "disconnect"],
            "reconnect revalidates identity and mount before disconnect"); checks += 1
        func rejects(_ expected: NASRuntimeFailure, validate: () throws -> Void,
                     verify: () throws -> Void, credential: () throws -> Void,
                     disconnect: () throws -> Void, expectedEvents: [String], label: String) {
            events = []
            do {
                _ = try NASArchiveMount.reuseExisting(validate: validate, verifyEncryption: verify,
                    checkCredential: credential, disconnect: disconnect)
                require(false, label + " accepted")
            } catch {
                require((error as? NASRuntimeFailure) == expected && events == expectedEvents, label)
                checks += 1
            }
        }
        rejects(.sourceChanged, validate: { throw NASRuntimeFailure.sourceChanged }, verify: encrypted,
            credential: credential, disconnect: disconnect, expectedEvents: [], label: "foreign mount stays mounted")
        rejects(.revoked, validate: { throw NASRuntimeFailure.revoked }, verify: encrypted,
            credential: credential, disconnect: disconnect, expectedEvents: [], label: "revoked identity stays mounted")
        rejects(.revoked, validate: validate, verify: unencrypted, credential: { throw NASRuntimeFailure.revoked },
            disconnect: disconnect, expectedEvents: ["validate", "unencrypted"], label: "revocation before disconnect stops recovery")
        rejects(.invalidReply, validate: validate, verify: { throw NASRuntimeFailure.invalidReply },
            credential: credential, disconnect: disconnect, expectedEvents: ["validate"], label: "unknown encryption stays mounted")
        rejects(.nasBusy, validate: validate, verify: unencrypted, credential: credential,
            disconnect: { events.append("busy"); throw NASRuntimeFailure.nasBusy },
            expectedEvents: ["validate", "unencrypted", "credential", "validate", "busy"], label: "busy mount is never forced")
        var validations = 0
        rejects(.sourceChanged, validate: {
            validations += 1; events.append("validate")
            if validations == 2 { throw NASRuntimeFailure.sourceChanged }
        }, verify: unencrypted, credential: credential, disconnect: disconnect,
            expectedEvents: ["validate", "unencrypted", "credential", "validate"], label: "mount changed during recovery stays mounted")
        for algorithm in ["AES_128_GCM", "AES_256_GCM", "AES_128_CCM", "AES_256_CCM"] {
            try NASArchiveMount.requireEncryptedSMB3([["SMB_VERSION": "SMB_3.1.1", "SMB_CURR_ENCRYPT_ALGORITHM": algorithm]])
            checks += 1
        }
        for (record, expected) in [
            (["SMB_VERSION": "SMB_3.1.1", "SMB_CURR_ENCRYPT_ALGORITHM": NSNull()], NASRuntimeFailure.accessDenied),
            (["SMB_VERSION": "SMB_3.1.1", "SMB_ENCRYPTION_SUPPORTED": true], NASRuntimeFailure.invalidReply),
            (["SMB_VERSION": "SMB_3.1.1", "SMB_CURR_ENCRYPT_ALGORITHM": "FUTURE_UNKNOWN"], NASRuntimeFailure.invalidReply),
            (["SMB_VERSION": "SMB_2.1", "SMB_CURR_ENCRYPT_ALGORITHM": "AES_128_GCM"], NASRuntimeFailure.invalidReply)
        ] as [([String: Any], NASRuntimeFailure)] {
            do { try NASArchiveMount.requireEncryptedSMB3([record]); require(false, "unverified encryption accepted") }
            catch { require((error as? NASRuntimeFailure) == expected, "unverified encryption classification"); checks += 1 }
        }
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"real_credentials\":false,\"mount_operations\":0}")
    }
}
