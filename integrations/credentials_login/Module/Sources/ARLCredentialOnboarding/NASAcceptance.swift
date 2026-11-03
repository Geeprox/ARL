import Foundation
import Darwin
import CryptoKit
import CoreFoundation

/// The only writable acceptance surface: this reviewed six-file manifest,
/// existing home/ARL-Test scope and two fixed lifecycle phases. No caller bytes.
public enum NASAcceptancePhase: String, Sendable { case create, cleanup }
public struct NASAcceptanceSample: Sendable {
    public let name: String
    public let size: Int
    public let sha256: String
}
public enum NASAcceptanceProtocol {
    public static let manifestSHA256 = "f49588e49abac09328eb2a5a3ec6026548ebc610d28ac9b7f24f3822556a39d1"
    public static let samples: [NASAcceptanceSample] = [
        .init(name:"ARL-Test-20261030-document.docx", size:1125, sha256:"a846e58472b6d00ae50ab8d56b0670af80eba57ca906b90f1c70f61d902644c1"),
        .init(name:"ARL-Test-20261030-document.pdf", size:622, sha256:"a8467c0243af29462c3bf56704aa1c82d056a374b7181ef3694d0871aa6068eb"),
        .init(name:"ARL-Test-20261030-document.pptx", size:2022, sha256:"6c3fd37073ff8f7c55e012d37298471a8e036858965f41cd225043feae5c489a"),
        .init(name:"ARL-Test-20261030-document.xlsx", size:1995, sha256:"7dc1c0bf38d564066361b8d30add64456c761d53825720fdc4894688d9cbb928"),
        .init(name:"ARL-Test-20261030-large.bin", size:3145745, sha256:"ffd555e1e3d2783cdc2d051c6a0f04a5146e169d6e992e90b6cfd79552bc7f20"),
        .init(name:"ARL-Test-20261030-write.txt", size:64, sha256:"20a00acd6e79f0345ec3bc6a4ad976dc5bb5a81cd56a711b809d34b43061ff17")
    ]
    public static func validate(configuration: NASConnectionConfiguration, approvedManifestSHA256: String) throws {
        guard approvedManifestSHA256 == manifestSHA256, configuration.share == "home", configuration.root == "ARL-Test"
        else { throw CredentialError.invalidInput }
    }
    static func validateResponse(_ data: Data, phase: NASAcceptancePhase) throws {
        let value = try MusicStrictJSON.object(data, limit: 65536)
        guard Set(value.keys) == ["schema_version","operation","phase","manifest_sha256","state","files","automatic_replay","read_scope_changed"],
              MusicRuntimeResources.integer(value["schema_version"]) == 1,
              value["operation"] as? String == "nas_acceptance", value["phase"] as? String == phase.rawValue,
              value["manifest_sha256"] as? String == manifestSHA256,
              let state = value["state"] as? String, ["complete","needs_review","blocked"].contains(state),
              let replay = value["automatic_replay"] as? NSNumber, CFGetTypeID(replay) == CFBooleanGetTypeID(), !replay.boolValue,
              let changed = value["read_scope_changed"] as? NSNumber, CFGetTypeID(changed) == CFBooleanGetTypeID(), !changed.boolValue,
              let files = value["files"] as? [[String:Any]], files.count <= samples.count
        else { throw NASRuntimeFailure.invalidReply }
        var names = Set<String>()
        for row in files {
            guard Set(row.keys) == ["name","size","sha256","state","object_ref","revision","object_identity","error"],
                  let name = row["name"] as? String, names.insert(name).inserted,
                  let expected = samples.first(where: { $0.name == name }),
                  MusicRuntimeResources.integer(row["size"]) == expected.size,
                  row["sha256"] as? String == expected.sha256,
                  let phaseState = row["state"] as? String,
                  ["created_verified","deleted","not_started","unknown","not_created","target_changed"].contains(phaseState)
            else { throw NASRuntimeFailure.invalidReply }
            for key in ["object_ref","revision","object_identity"] {
                guard row[key] is NSNull || (row[key] as? String).map(MusicRuntimeResources.validHash) == true
                else { throw NASRuntimeFailure.invalidReply }
            }
            guard row["error"] is NSNull || (row["error"] as? String)?.range(of:"^[a-z_]{1,96}$",options:.regularExpression) != nil
            else { throw NASRuntimeFailure.invalidReply }
            if state == "complete" {
                guard phaseState == (phase == .create ? "created_verified":"deleted"),
                      row["error"] is NSNull, ["object_ref","revision","object_identity"].allSatisfy({ row[$0] is String })
                else { throw NASRuntimeFailure.invalidReply }
            }
        }
        if state == "complete", files.count != samples.count { throw NASRuntimeFailure.invalidReply }
    }
}

/// One private pipe exchange; durable per-object claims live in this exact
/// native-pinned journal directory in the existing host. No public grant DTO.
final class NASAcceptanceAuthorization: @unchecked Sendable {
    let phase: NASAcceptancePhase
    let planDigest: String
    let journalDescriptor: [String:Any]
    private let fd: Int32
    private let directory: URL
    private let device: dev_t, inode: ino_t
    private let verifyOwner: @Sendable () throws -> Void
    private let deadline = ProcessInfo.processInfo.systemUptime + 90
    private var consumed = false
    init(phase: NASAcceptancePhase, configuration: NASConnectionConfiguration, directory: URL,
         verify: @escaping @Sendable () throws -> Void) throws {
        try NASAcceptanceProtocol.validate(configuration:configuration,approvedManifestSHA256:NASAcceptanceProtocol.manifestSHA256)
        self.phase=phase; self.directory=directory; verifyOwner=verify
        planDigest=digest(Data((NASAcceptanceProtocol.manifestSHA256+"\u{0}"+phase.rawValue).utf8))
        try verify()
        let parent=try MusicRuntimeResources.directory(directory.deletingLastPathComponent().path)
        defer { Darwin.close(parent) }
        if mkdirat(parent,directory.lastPathComponent,0o700) != 0 && errno != EEXIST { throw CredentialError.storageUnavailable }
        fd=openat(parent,directory.lastPathComponent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw CredentialError.storageUnavailable }
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&0o7777==0o700 else { Darwin.close(fd);throw CredentialError.uncertainLocalState }
        device=info.st_dev;inode=info.st_ino
        journalDescriptor=["path":directory.path,"dev":Int64(info.st_dev),"ino":UInt64(info.st_ino)]
    }
    func authorize(consume: Bool) throws {
        try verifyOwner()
        var opened=stat(),named=stat()
        guard ProcessInfo.processInfo.systemUptime < deadline,
              fstat(fd,&opened)==0,lstat(directory.path,&named)==0,
              opened.st_dev==device,opened.st_ino==inode,named.st_dev==device,named.st_ino==inode,
              opened.st_uid==getuid(),opened.st_mode&0o7777==0o700,named.st_mode&S_IFMT==S_IFDIR
        else { throw CredentialError.uncertainLocalState }
        if consume { guard !consumed else { throw CredentialError.staleReference };consumed=true }
    }
    var remaining: Double { max(0,deadline-ProcessInfo.processInfo.systemUptime) }
    deinit { Darwin.close(fd) }
}
