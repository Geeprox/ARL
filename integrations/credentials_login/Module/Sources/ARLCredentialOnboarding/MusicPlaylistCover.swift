import Foundation
import Darwin
import CryptoKit
import ImageIO

/// A normal cover change supplies its playlist and image. The caller-generated
/// request ID is the existing transport idempotency key, never an image hash.
public struct MusicPlaylistCoverRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let playlistID: String
    public let imageURL: URL?
    /// A song_id already returned by the selected playlist; use its coverImgUrl.
    public let imageReference: String?
    public let reconcileOnly: Bool
    public init(requestID: UUID, playlistID: String, imageURL: String? = nil,
                imageReference: String? = nil, reconcileOnly: Bool = false) throws {
        guard MusicReadProtocol.validID(playlistID), (imageURL == nil) != (imageReference == nil) else { throw CredentialError.invalidInput }
        self.requestID = requestID; self.playlistID = playlistID.lowercased(); self.reconcileOnly = reconcileOnly
        if let text = imageURL {
            guard let url = Self.imageURL(text) else { throw CredentialError.invalidInput }
            self.imageURL = url; self.imageReference = nil
        } else {
            guard let imageReference, MusicReadProtocol.validID(imageReference) else { throw CredentialError.invalidInput }
            self.imageReference = imageReference.lowercased(); self.imageURL = nil
        }
    }
    enum CodingKeys: String, CodingKey { case requestID, playlistID, imageURL, imageReference, reconcileOnly }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestID: values.decode(UUID.self, forKey: .requestID), playlistID: values.decode(String.self, forKey: .playlistID),
            imageURL: values.decodeIfPresent(String.self, forKey: .imageURL), imageReference: values.decodeIfPresent(String.self, forKey: .imageReference),
            reconcileOnly: values.decodeIfPresent(Bool.self, forKey: .reconcileOnly) ?? false)
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.requestID == b.requestID && a.playlistID == b.playlistID && a.imageURL == b.imageURL && a.imageReference == b.imageReference
    }
    static func imageURL(_ text: String) -> URL? {
        guard !text.isEmpty, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var parts = URLComponents(string: text), parts.user == nil, parts.password == nil,
              let host = parts.host, !host.isEmpty else { return nil }
        // Official read records use http CDN URLs. Fetch that same resource over
        // HTTPS without rewriting its original provider record.
        if parts.scheme == "http", ["p1.music.126.net", "p2.music.126.net"].contains(host) { parts.scheme = "https" }
        guard parts.scheme == "https" else { return nil }
        return parts.url
    }
}

public struct MusicPlaylistCoverResult: Codable, Sendable {
    public let requestID: UUID
    public let playlistID: String
    public var state: String
    public var readbackVerified = false
    public var providerResponse: MusicProviderRecord?
    public var providerResponseComplete = false
    public var providerExchange: MusicProviderRecord?
    public var uploadReceipts: [MusicProviderRecord] = []
    public var playlist: MusicReadPlaylist?
    public var recoveryAttempt: Int?
    public var originalState: String?
    public var stagedImageCleanup: String?
    public let automaticReplay = false
    public let newSubmissionAllowed = false
    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", playlistID = "playlist_id", state
        case readbackVerified = "readback_verified", providerResponse = "provider_response"
        case providerResponseComplete = "provider_response_complete", providerExchange = "provider_exchange"
        case recoveryAttempt = "recovery_attempt", originalState = "original_state"
        case stagedImageCleanup = "staged_image_cleanup"
        case uploadReceipts = "upload_receipts", playlist, automaticReplay = "automatic_replay", newSubmissionAllowed = "new_submission_allowed"
    }
    init(_ state: String, request: MusicPlaylistCoverRequest) { self.state = state; requestID = request.requestID; playlistID = request.playlistID }
}

struct MusicPlaylistCoverRuntimeRequest: Sendable {
    let playlistID: String
    let fileURL: URL
    let sha256: String
    let bytes: Int
    var arguments: [String: String] {
        ["playlist_id": playlistID, "image_path": fileURL.path, "image_sha256": sha256, "image_bytes": String(bytes)]
    }
}
struct MusicPlaylistCoverEffect: Sendable {
    let state: String
    let credential: CredentialInput
    var resourceID: String?
    var providerResponse: MusicProviderRecord?
    var providerResponseComplete = true
    var providerExchange: MusicProviderRecord?
    var uploadReceipts: [MusicProviderRecord] = []
}
protocol MusicPlaylistCoverTransport: Sendable {
    func coverRuntimeGeneration() throws -> String
    func sendCover(_ secret: CredentialInput, request: MusicPlaylistCoverRuntimeRequest) async throws -> MusicPlaylistCoverEffect
}
extension MusicPlaylistCoverTransport {
    func coverRuntimeGeneration() throws -> String { throw CredentialError.deploymentNotApproved }
}

struct MusicPlaylistCoverRecoveryProof: Codable, Equatable {
    let originalDigest: String
    let imageSHA256: String
    let imageBytes: Int
    let originalBridgeSHA256: String
    let evidenceSHA256: String
}
struct MusicPlaylistCoverRecoveryAttempt: Codable {
    let generation: String
    var record: MusicPlaylistCoverRecord
}
struct MusicPlaylistCoverRecoveryLedger: Codable {
    var schema = 1
    let proof: MusicPlaylistCoverRecoveryProof
    var attempts: [MusicPlaylistCoverRecoveryAttempt] = []
}

protocol MusicPlaylistCoverImageLoader: Sendable { func load(_ url: URL) async throws -> Data }
private final class CoverRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { MusicPlaylistCoverRequest.imageURL($0.absoluteString) } == request.url ? request : nil)
    }
}
struct MusicPlaylistCoverHTTPSImageLoader: MusicPlaylistCoverImageLoader {
    func load(_ url: URL) async throws -> Data {
        guard MusicPlaylistCoverRequest.imageURL(url.absoluteString) == url else { throw CredentialError.invalidInput }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: CoverRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 180))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw CredentialError.uncertainLocalState }
        return bytes
    }
}

struct MusicPlaylistCoverRecord: Codable {
    let request: MusicPlaylistCoverRequest
    let reference: UUID
    let epoch: UUID
    let baselineCover: String?
    let baselineSongs: [String]?
    var resourceID: String?
    var effectState: String?
    var result: MusicPlaylistCoverResult?
    var providerResponse: MusicProviderRecord?
    var providerResponseComplete: Bool? = nil
    var providerExchange: MusicProviderRecord?
    var uploadReceipts: [MusicProviderRecord]? = nil
}
struct MusicPlaylistCoverLedger: Codable { var schema = 1; var records: [String: MusicPlaylistCoverRecord] = [:] }
protocol MusicPlaylistCoverJournal: Sendable {
    func inspect(_ id: UUID) throws -> MusicPlaylistCoverRecord?
    func reserve(_ record: MusicPlaylistCoverRecord) throws
    func save(_ record: MusicPlaylistCoverRecord) throws
    func stage(_ bytes: Data, id: UUID) throws -> MusicPlaylistCoverRuntimeRequest
    func removeImage(_ file: URL) throws
}

/// Separate owner-only cover receipts. No upload token is persisted here.
final class FileMusicPlaylistCoverJournal: MusicPlaylistCoverJournal, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    // A live pre-reservation stage holds this inode lock until cleanup. A dead
    // process releases it in the kernel, so its unreserved image is recoverable.
    private var images: [String: Int32] = [:]
    init(directory: URL) { self.directory = directory }
    deinit { for fd in images.values { flock(fd, LOCK_UN); close(fd) } }
    private func directoryFD(create: Bool) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw CredentialError.storageUnavailable }
        do {
            for part in directory.pathComponents.dropFirst() {
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, part, 0o700) == 0 || errno == EEXIST else { throw CredentialError.storageUnavailable }
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw CredentialError.storageUnavailable }
                close(fd); fd = next
            }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 else { throw CredentialError.uncertainLocalState }
            return fd
        } catch { close(fd); throw error }
    }
    private func perform<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            let fd = try directoryFD(create: true); defer { close(fd) }
            let gate = openat(fd, "cover.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard gate >= 0 else { throw CredentialError.storageUnavailable }; defer { close(gate) }
            var st = stat()
            guard fstat(gate, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
                  st.st_mode & 0o777 == 0o600, st.st_nlink == 1 else { throw CredentialError.uncertainLocalState }
            guard flock(gate, LOCK_EX | LOCK_NB) == 0 else { throw CredentialError.busy }
            defer { flock(gate, LOCK_UN) }
            return try body(fd)
        }
    }
    private func ledger(_ fd: Int32) throws -> MusicPlaylistCoverLedger {
        var st = stat()
        if fstatat(fd, "covers.json", &st, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw CredentialError.storageUnavailable }; return .init()
        }
        guard st.st_uid == getuid(), st.st_nlink == 1, st.st_size > 0, st.st_size <= Int.max else { throw CredentialError.uncertainLocalState }
        let bytes = try MusicRuntimeResources.read(root: directory, relative: "covers.json", bytes: Int(st.st_size), mode: 0o600)
        _ = try MusicStrictJSON.object(bytes, limit: bytes.count, maximumDepth: 32)
        let value = try JSONDecoder().decode(MusicPlaylistCoverLedger.self, from: bytes)
        guard value.schema == 1, value.records.allSatisfy({ $0.key == $0.value.request.requestID.uuidString }) else { throw CredentialError.uncertainLocalState }
        return value
    }
    private func write(_ bytes: Data, name: String, fd: Int32, replace: Bool) throws {
        let temporary = replace ? UUID().uuidString + ".tmp" : name
        let f = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { throw CredentialError.storageUnavailable }; defer { close(f) }
        do {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(f, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw CredentialError.storageUnavailable }; offset += n
                }
            }
            guard fsync(f) == 0, !replace || renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw CredentialError.storageUnavailable }
        } catch { _ = unlinkat(fd, temporary, 0); throw error }
    }
    func inspect(_ id: UUID) throws -> MusicPlaylistCoverRecord? {
        try perform { fd in
            var record = try ledger(fd).records[id.uuidString]
            // A terminal result is saved only after the runtime cleanup barrier.
            // Retry failed image cleanup on every same-ID query without blocking
            // the cached business result. Pending/unknown records never restage.
            if record?.result != nil {
                do { try reapImages(id, fd: fd); record?.result?.stagedImageCleanup = nil }
                catch { record?.result?.stagedImageCleanup = "pending" }
            }
            return record
        }
    }
    func reserve(_ record: MusicPlaylistCoverRecord) throws {
        try perform { fd in
            var value = try ledger(fd)
            guard value.records[record.request.requestID.uuidString] == nil else { throw CredentialError.busy }
            value.records[record.request.requestID.uuidString] = record
            try write(JSONEncoder().encode(value), name: "covers.json", fd: fd, replace: true)
        }
    }
    func save(_ record: MusicPlaylistCoverRecord) throws {
        try perform { fd in
            var value = try ledger(fd)
            guard let old = value.records[record.request.requestID.uuidString], old.request == record.request,
                  old.reference == record.reference, old.epoch == record.epoch, old.baselineCover == record.baselineCover,
                  old.baselineSongs == record.baselineSongs else { throw CredentialError.uncertainLocalState }
            value.records[record.request.requestID.uuidString] = record
            try write(JSONEncoder().encode(value), name: "covers.json", fd: fd, replace: true)
        }
    }
    private func recordDigest(_ record: MusicPlaylistCoverRecord) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return MusicRuntimeResources.hash(try encoder.encode(record))
    }
    private func recovery(_ id: UUID, original: MusicPlaylistCoverRecord, fd: Int32) throws -> MusicPlaylistCoverRecoveryLedger? {
        let name = "recovery-" + id.uuidString + ".json"
        var st = stat()
        if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw CredentialError.storageUnavailable }; return nil
        }
        guard st.st_uid == getuid(), st.st_nlink == 1, st.st_size > 0, st.st_size <= Int.max else { throw CredentialError.uncertainLocalState }
        let raw = try MusicRuntimeResources.read(root: directory, relative: name, bytes: Int(st.st_size), mode: 0o600)
        _ = try MusicStrictJSON.object(raw, limit: raw.count, maximumDepth: 32)
        let value = try JSONDecoder().decode(MusicPlaylistCoverRecoveryLedger.self, from: raw)
        guard value.schema == 1, value.proof.originalDigest == (try recordDigest(original)),
              MusicRuntimeResources.validHash(value.proof.imageSHA256), value.proof.imageBytes > 0,
              MusicRuntimeResources.validHash(value.proof.originalBridgeSHA256), MusicRuntimeResources.validHash(value.proof.evidenceSHA256),
              !value.attempts.isEmpty, Set(value.attempts.map(\.generation)).count == value.attempts.count,
              value.attempts.allSatisfy({ a in
                  MusicRuntimeResources.validHash(a.generation) && a.record.request == original.request &&
                  a.record.reference == original.reference && a.record.epoch == original.epoch &&
                  a.record.baselineCover == original.baselineCover && a.record.baselineSongs == original.baselineSongs
              }) else { throw CredentialError.uncertainLocalState }
        return value
    }
    func inspectRecovery(_ id: UUID) throws -> MusicPlaylistCoverRecoveryLedger? {
        try perform { fd in
            guard let original = try ledger(fd).records[id.uuidString] else { return nil }
            return try recovery(id, original: original, fd: fd)
        }
    }
    /// A known token-reply failure is the only terminal result eligible for
    /// another reviewed bridge generation. No resource or upload can exist.
    static func tokenFailure(_ record: MusicPlaylistCoverRecord) -> Bool {
        guard record.effectState == "not_submitted", record.resourceID == nil,
              let result = record.result, result.state == "not_dispatched", result.uploadReceipts.isEmpty,
              record.uploadReceipts?.isEmpty != false, let fields = result.providerExchange?.fields,
              fields["path"] == .text("/openapi/whale/nos/upload/token/docid"), fields["http_status"] == .integer(200),
              fields["failure_code"] == .text("invalid_cover_token_reply"), fields["failure_stage"] == .text("provider"),
              case .object(let check) = fields["cover_token_validation"],
              check["boundary"] == .text("token_reply_before_nos"), check["token_accepted"] == .boolean(false),
              check["cover_update_dispatched"] == .boolean(false) else { return false }
        return true
    }
    private func eligible(_ value: MusicPlaylistCoverRecoveryLedger?, generation: String) throws {
        guard MusicRuntimeResources.validHash(generation), value?.attempts.contains(where: { $0.generation == generation }) != true,
              value?.attempts.last.map({ Self.tokenFailure($0.record) }) ?? true else { throw CredentialError.busy }
    }
    func recoveryProof(_ id: UUID, generation: String) throws -> MusicPlaylistCoverRecoveryProof {
        try perform { fd in
            guard let original = try ledger(fd).records[id.uuidString], original.effectState == "not_submitted",
                  original.resourceID == nil, original.result?.state == "not_dispatched", original.result?.uploadReceipts.isEmpty == true,
                  original.uploadReceipts?.isEmpty != false, original.baselineSongs != nil,
                  MusicPlaylistCoverVerification.resource(original.baselineCover) != nil else { throw CredentialError.uncertainLocalState }
            let value = try recovery(id, original: original, fd: fd)
            try eligible(value, generation: generation)
            if let value { return value.proof }
            // Build92 did not yet project its safe token-boundary diagnostic.
            // Accept its complete owner journal, never a caller-supplied proof.
            return try legacyTokenProof(original)
        }
    }
    func stageRecovery(_ bytes: Data, id: UUID, generation: String, proof: MusicPlaylistCoverRecoveryProof) throws -> MusicPlaylistCoverRuntimeRequest {
        guard bytes.count == proof.imageBytes, MusicRuntimeResources.hash(bytes) == proof.imageSHA256,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type) else { throw CredentialError.invalidInput }
        let name = id.uuidString + (type == "public.png" ? ".png" : ".jpg")
        try perform { fd in
            guard let original = try ledger(fd).records[id.uuidString], proof.originalDigest == (try recordDigest(original)) else { throw CredentialError.uncertainLocalState }
            let value = try recovery(id, original: original, fd: fd)
            guard value == nil || value?.proof == proof else { throw CredentialError.uncertainLocalState }
            try eligible(value, generation: generation)
            try reapImages(id, fd: fd); try write(bytes, name: name, fd: fd, replace: false)
            guard let image = try imageFD(name, fd: fd) else { throw CredentialError.storageUnavailable }
            images[name] = image
        }
        return .init(playlistID: "", fileURL: directory.appendingPathComponent(name), sha256: proof.imageSHA256, bytes: bytes.count)
    }
    /// fsync the exclusive attempt before any token/NOS/update call. The base
    /// covers.json record is never saved, replaced or relabelled by recovery.
    func reserveRecovery(_ record: MusicPlaylistCoverRecord, generation: String, proof: MusicPlaylistCoverRecoveryProof) throws -> Int {
        try perform { fd in
            let id = record.request.requestID
            guard let original = try ledger(fd).records[id.uuidString], proof.originalDigest == (try recordDigest(original)),
                  record.request == original.request, record.reference == original.reference, record.epoch == original.epoch,
                  record.baselineCover == original.baselineCover, record.baselineSongs == original.baselineSongs,
                  record.result == nil, record.effectState == nil, record.resourceID == nil else { throw CredentialError.uncertainLocalState }
            let previous = try recovery(id, original: original, fd: fd)
            guard previous == nil || previous?.proof == proof else { throw CredentialError.uncertainLocalState }
            try eligible(previous, generation: generation)
            var next = previous ?? MusicPlaylistCoverRecoveryLedger(proof: proof)
            next.attempts.append(.init(generation: generation, record: record))
            try write(JSONEncoder().encode(next), name: "recovery-" + id.uuidString + ".json", fd: fd, replace: true)
            return next.attempts.count
        }
    }
    func saveRecovery(_ record: MusicPlaylistCoverRecord, attempt: Int) throws {
        try perform { fd in
            let id = record.request.requestID
            guard let original = try ledger(fd).records[id.uuidString], var value = try recovery(id, original: original, fd: fd),
                  attempt > 0, value.attempts.count == attempt else { throw CredentialError.uncertainLocalState }
            let old = value.attempts[attempt - 1].record
            guard old.result == nil, old.request == record.request, old.reference == record.reference, old.epoch == record.epoch,
                  old.baselineCover == record.baselineCover, old.baselineSongs == record.baselineSongs else { throw CredentialError.uncertainLocalState }
            value.attempts[attempt - 1].record = record
            try write(JSONEncoder().encode(value), name: "recovery-" + id.uuidString + ".json", fd: fd, replace: true)
        }
    }
    private func legacyTokenProof(_ original: MusicPlaylistCoverRecord) throws -> MusicPlaylistCoverRecoveryProof {
        let home = directory.deletingLastPathComponent().appendingPathComponent("music-business-v1.noindex")
        let fd = try MusicRuntimeResources.directory(home.path); defer { close(fd) }
        func secure(_ f: Int32, type: mode_t, mode: mode_t) throws {
            var st = stat()
            guard f >= 0, fstat(f, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == type,
                  st.st_mode & 0o777 == mode, type != S_IFREG || st.st_nlink == 1 else { throw CredentialError.uncertainLocalState }
        }
        try secure(fd, type: S_IFDIR, mode: 0o700)
        let gate = openat(fd, "business.lock.noindex", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard gate >= 0 else { throw CredentialError.uncertainLocalState }; defer { close(gate) }
        try secure(gate, type: S_IFREG, mode: 0o600)
        guard flock(gate, LOCK_SH | LOCK_NB) == 0 else { throw CredentialError.busy }; defer { flock(gate, LOCK_UN) }
        var requests: [[String: Any]] = [], completes: [[String: Any]] = [], frames: [[String: Any]] = []
        var starts: [String: Int] = [:], ends: [String: Int] = [:]
        let readOperations: Set<String> = ["user_playlists", "playlist_detail"]
        var evidence = SHA256()
        for name in try FileManager.default.contentsOfDirectory(atPath: home.path).sorted()
            where name.hasPrefix("business-") && name.hasSuffix(".jsonl.noindex") {
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw CredentialError.uncertainLocalState }; defer { close(file) }
            try secure(file, type: S_IFREG, mode: 0o600)
            var pending = Data(), buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(file, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw CredentialError.storageUnavailable }
                if count == 0 { break }; pending.append(contentsOf: buffer.prefix(count))
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end]); pending.removeSubrange(...end)
                    let row = try MusicStrictJSON.object(line, limit: line.count, maximumDepth: 32)
                    guard row["request_id"] as? String == original.request.requestID.uuidString else { continue }
                    guard MusicRuntimeResources.integer(row["schema"]) == 1 else { throw CredentialError.uncertainLocalState }
                    evidence.update(data: line)
                    if row["event"] as? String == "runtime_interrupted" { throw CredentialError.uncertainLocalState }
                    if let event = row["event"] as? String, ["runtime_request", "runtime_complete"].contains(event) {
                        guard let operation = row["operation"] as? String,
                              operation == "playlist_cover" || readOperations.contains(operation),
                              let text = row["call_id"] as? String, let caller = UUID(uuidString: text)
                              else { throw CredentialError.uncertainLocalState }
                        // Current owner metadata and completed readonly calls may
                        // surround the legacy receipt; only its effect is build92.
                        if operation == "playlist_cover", row["build"] as? String != "92" { throw CredentialError.uncertainLocalState }
                        let key = caller.uuidString + "|" + operation
                        if event == "runtime_request" {
                            starts[key, default: 0] += 1
                            if operation == "playlist_cover" { requests.append(row) }
                        } else {
                            if operation != "playlist_cover" {
                                guard let state = row["state"] as? String, MusicReadState(rawValue: state) != nil
                                      else { throw CredentialError.uncertainLocalState }
                            }
                            ends[key, default: 0] += 1
                            if operation == "playlist_cover" { completes.append(row) }
                        }
                    }
                    if row["event"] as? String == "business_record" { frames.append(row) }
                }
            }
            guard pending.isEmpty else { throw CredentialError.uncertainLocalState }
        }
        guard starts == ends, requests.count == 1, completes.count == 1, completes[0]["state"] as? String == "not_submitted",
              let call = requests[0]["call_id"] as? String, let originalCall = UUID(uuidString: call),
              let completedCall = completes[0]["call_id"] as? String, UUID(uuidString: completedCall) == originalCall,
              let args = requests[0]["arguments"] as? [String: Any], args["playlist_id"] as? String == original.request.playlistID,
              let imageHash = args["image_sha256"] as? String, MusicRuntimeResources.validHash(imageHash),
              let countText = args["image_bytes"] as? String, let imageBytes = Int(countText), imageBytes > 0,
              let path = args["image_path"] as? String, URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              [original.request.requestID.uuidString + ".jpg", original.request.requestID.uuidString + ".png"].contains(URL(fileURLWithPath: path).lastPathComponent)
              else { throw CredentialError.uncertainLocalState }
        var groups: [String: [[String: Any]]] = [:]
        // Classify every same-request record, including foreign calls. Dropping
        // a frame before decoding can hide a possibly dispatched second effect.
        for row in frames {
            guard let text = row["call_id"] as? String, let caller = UUID(uuidString: text),
                  let key = row["record_id"] as? String, let record = UUID(uuidString: key)
                  else { throw CredentialError.uncertainLocalState }
            groups[caller.uuidString + "|" + record.uuidString, default: []].append(row)
        }
        var failures = 0, tokenRequests = 0
        for rows in groups.values {
            let ordered = rows.sorted { (MusicRuntimeResources.integer($0["part"]) ?? -1) < (MusicRuntimeResources.integer($1["part"]) ?? -1) }
            guard let first = ordered.first, let parts = MusicRuntimeResources.integer(first["parts"]), parts == ordered.count,
                  let hash = first["sha256"] as? String, MusicRuntimeResources.validHash(hash) else { throw CredentialError.uncertainLocalState }
            var bytes = Data()
            for (index, row) in ordered.enumerated() {
                guard MusicRuntimeResources.integer(row["part"]) == index, MusicRuntimeResources.integer(row["parts"]) == parts,
                      row["sha256"] as? String == hash, let text = row["payload"] as? String, let data = Data(base64Encoded: text),
                      data.base64EncodedString() == text, data.count <= 65536 else { throw CredentialError.uncertainLocalState }
                bytes.append(data)
            }
            guard MusicRuntimeResources.hash(bytes) == hash else { throw CredentialError.uncertainLocalState }
            let row = try MusicStrictJSON.object(bytes, limit: bytes.count, maximumDepth: 32)
            guard let operation = row["operation"] as? String, let text = first["call_id"] as? String,
                  let caller = UUID(uuidString: text), let path = row["path"] as? String,
                  let count = starts[caller.uuidString + "|" + operation], count > 0,
                  ends[caller.uuidString + "|" + operation] == count
                  else { throw CredentialError.uncertainLocalState }
            let coverActivity = path == "/openapi/whale/nos/upload/token/docid" ||
                path == "/openapi/music/basic/playlist/cover/update" || path.hasPrefix("/yyimgs/") ||
                row["event"] as? String == "upload_response"
            if operation != "playlist_cover" {
                guard readOperations.contains(operation), !coverActivity else { throw CredentialError.uncertainLocalState }
                continue
            }
            guard caller == originalCall, rows.allSatisfy({ $0["build"] as? String == "92" }),
                  ["/openapi/v1/ncm/cli/manifest", "/openapi/whale/nos/upload/token/docid"].contains(path)
                  else { throw CredentialError.uncertainLocalState }
            // Build92 guards token acceptance before NOS. Reject any evidence
            // of upload or update, or a second token exchange, rather than infer.
            if row["path"] as? String == "/openapi/whale/nos/upload/token/docid" {
                guard row["method"] as? String == "POST" else { throw CredentialError.uncertainLocalState }
                if row["event"] as? String == "http_request" { tokenRequests += 1 }
                else {
                    guard row["event"] as? String == "http_failure", MusicRuntimeResources.integer(row["http_status"]) == 200,
                          row["failure_stage"] as? String == "provider", row["failure_code"] as? String == "invalid_cover_token_reply"
                          else { throw CredentialError.uncertainLocalState }
                    failures += 1
                }
            } else if row["event"] as? String == "upload_response" || row["path"] as? String == "/openapi/music/basic/playlist/cover/update" {
                throw CredentialError.uncertainLocalState
            }
        }
        guard failures == 1, tokenRequests == 1 else { throw CredentialError.uncertainLocalState }
        return .init(originalDigest: try recordDigest(original), imageSHA256: imageHash, imageBytes: imageBytes,
            originalBridgeSHA256: "cc2d69326235cd0b01bee8f0dff22c2dd1e374336d935c758652aa7a55f1100c",
            evidenceSHA256: evidence.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func imageFD(_ name: String, fd: Int32) throws -> Int32? {
        let image = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if image < 0, errno == ENOENT { return nil }
        guard image >= 0 else { throw CredentialError.storageUnavailable }
        var st = stat()
        guard fstat(image, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o777 == 0o600, st.st_nlink == 1 else { close(image); throw CredentialError.uncertainLocalState }
        guard flock(image, LOCK_EX | LOCK_NB) == 0 else { close(image); throw CredentialError.busy }
        return image
    }
    private func reapImages(_ id: UUID, fd: Int32) throws {
        for suffix in [".png", ".jpg"] {
            let name = id.uuidString + suffix
            guard images[name] == nil else { throw CredentialError.busy }
            guard let image = try imageFD(name, fd: fd) else { continue }
            defer { flock(image, LOCK_UN); close(image) }
            guard unlinkat(fd, name, 0) == 0 || errno == ENOENT else { throw CredentialError.storageUnavailable }
        }
        guard fsync(fd) == 0 else { throw CredentialError.storageUnavailable }
    }
    func stage(_ bytes: Data, id: UUID) throws -> MusicPlaylistCoverRuntimeRequest {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type) else { throw CredentialError.invalidInput }
        let name = id.uuidString + (type == "public.png" ? ".png" : ".jpg")
        try perform { fd in
            // Reservation is authoritative even after restart or unknown effect.
            guard try ledger(fd).records[id.uuidString] == nil else { throw CredentialError.busy }
            try reapImages(id, fd: fd)
            try write(bytes, name: name, fd: fd, replace: false)
            guard let image = try imageFD(name, fd: fd) else { throw CredentialError.storageUnavailable }
            images[name] = image
        }
        return .init(playlistID: "", fileURL: directory.appendingPathComponent(name),
                     sha256: MusicRuntimeResources.hash(bytes), bytes: bytes.count)
    }
    func removeImage(_ file: URL) throws {
        guard file.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else { throw CredentialError.invalidInput }
        do {
            try perform { fd in
                let name = file.lastPathComponent
                guard let image = images.removeValue(forKey: name) else { throw CredentialError.uncertainLocalState }
                defer { flock(image, LOCK_UN); close(image) }
                var current = stat(), linked = stat()
                if fstatat(fd, name, &linked, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else { throw CredentialError.storageUnavailable }; return
                }
                guard fstat(image, &current) == 0, current.st_dev == linked.st_dev, current.st_ino == linked.st_ino,
                      unlinkat(fd, name, 0) == 0, fsync(fd) == 0 else { throw CredentialError.storageUnavailable }
            }
        } catch {
            lock.withLock {
                if let image = images.removeValue(forKey: file.lastPathComponent) { flock(image, LOCK_UN); close(image) }
            }
            throw error
        }
    }
}

enum MusicPlaylistCoverVerification {
    static func coverURL(_ playlist: MusicReadPlaylist?) -> String? {
        guard case .text(let value) = playlist?.providerRecord?.fields["coverImgUrl"] else { return nil }; return value
    }
    /// The provider rotates p1/p2 without changing the actual image resource.
    /// Keep the entire encoded path and query binding, including the image hash.
    static func sameCover(_ a: String?, _ b: String?) -> Bool {
        if a == b { return true }
        guard let a, let b, let left = URLComponents(string: a), let right = URLComponents(string: b) else { return false }
        func official(_ value: URLComponents) -> Bool {
            ["http", "https"].contains(value.scheme ?? "") && ["p1.music.126.net", "p2.music.126.net"].contains(value.host ?? "") &&
                value.user == nil && value.password == nil && value.port == nil && value.fragment == nil
        }
        return official(left) && official(right) && left.percentEncodedPath == right.percentEncodedPath && left.percentEncodedQuery == right.percentEncodedQuery
    }
    static func resource(_ url: String?) -> String? {
        guard let url, let parsed = URL(string: url) else { return nil }
        return parsed.deletingPathExtension().lastPathComponent
    }
    static func verified(resourceID: String?, record: MusicPlaylistCoverRecord, read: MusicReadResult) -> Bool {
        guard let resourceID, read.state == .authorizedRead, let payload = read.payload,
              payload.playlist?.playlistID == record.request.playlistID,
              resource(coverURL(payload.playlist)) == resourceID else { return false }
        if let baseline = record.baselineSongs {
            guard payload.complete, payload.songs?.map(\.songID) == baseline else { return false }
        }
        return true
    }
}
