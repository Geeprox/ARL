import Foundation
import CryptoKit

private enum Check: Error { case failed(String) }
@main enum NASFileOperationsTests {
    static func main() throws {
        func expect(_ condition: Bool, _ name: String) throws { if !condition { throw Check.failed(name) } }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch is NASFileMutationFault { return }
            throw Check.failed(name)
        }
        func args(_ operation: String = "mkdir") -> [String: Any] {
            var value: [String: Any] = ["operation": operation, "operation_id": UUID().uuidString.lowercased(),
                "source_ref": "synthetic", "config_generation": 1, "connection_epoch": String(repeating: "e", count: 32),
                "name": "fixture.txt"]
            if operation != "download" { value["directory_ref"] = NSNull() }
            if operation == "move" || operation == "download" {
                value["object_ref"] = String(repeating: "a", count: 64); value["revision"] = String(repeating: "b", count: 64)
            }
            if operation == "download" { value["size"] = 0 }
            return value
        }
        let now = Date().timeIntervalSince1970
        let bytes = Data([0, 255, 1])
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let attachment: [String: Any] = ["transfer_kind": "inline_base64", "name": "fixture.txt", "size": bytes.count,
            "sha256": sha, "data_base64": bytes.base64EncodedString(), "expires_at": now + 90]
        var upload = args("upload_new"); upload["attachment"] = attachment
        let request = try NASFileMutationRequest(value: upload, now: now)
        var chunkUpload = args("upload_new")
        chunkUpload["transfer_ref"] = String(repeating: "d", count: 64)
        chunkUpload["size"] = 3 * 1024 * 1024 + 17; chunkUpload["sha256"] = sha
        let chunkRequest = try NASFileMutationRequest(value: chunkUpload, now: now)
        var manifest: [String: Any] = ["schema_version": 1, "operation_id": chunkRequest.operationID,
            "source_ref": chunkRequest.sourceRef, "config_generation": chunkRequest.generation, "connection_epoch": chunkRequest.epoch,
            "transfer_ref": chunkUpload["transfer_ref"]!, "name": "fixture.txt", "size": 3 * 1024 * 1024 + 17, "sha256": sha,
            "expires_in_seconds": 100, "complete": true, "direction": "upload", "downloadable_artifact": false]
        try chunkRequest.admitTransferManifest(manifest)
        manifest["source_ref"] = "other"
        try rejects("rebound_transfer") { try chunkRequest.admitTransferManifest(manifest) }
        let decoded = try NASFileTransferInput(value: attachment, now: now)
        try expect(decoded.bytes == bytes && decoded.sha256 == sha, "binary_exact")
        for operation in ["mkdir", "move", "download"] { _ = try NASFileMutationRequest(value: args(operation), now: now) }
        for (key, value) in [("name", "../outside" as Any), ("name", "CON.txt"), ("host", "outside.invalid"),
                             ("config_generation", true), ("config_generation", 1.5), ("directory_ref", "/tmp/file")] {
            var bad = args(); bad[key] = value
            try rejects("invalid_" + key) { _ = try NASFileMutationRequest(value: bad, now: now) }
        }
        for name in [".", "..", ".arl-upload-secret", "name.", "folder/name", "a\\b", "aux.txt"] {
            try expect(!NASFileMutationRequest.name(name), "name_rejected")
        }
        for (key, value) in [("size", true as Any), ("sha256", String(repeating: "0", count: 64)),
                             ("expires_at", now - 1), ("expires_at", Double.infinity), ("local_path", "/tmp/file")] {
            var bad = attachment; bad[key] = value
            try rejects("attachment_" + key) { _ = try NASFileTransferInput(value: bad, now: now) }
        }
        var reply: [String: Any] = ["schema_version": 1, "operation": "upload_new", "operation_id": request.operationID,
            "source_ref": request.sourceRef, "config_generation": request.generation, "connection_epoch": request.epoch,
            "status": "committed", "failure": NSNull(), "entry": NSNull(), "bytes_confirmed": bytes.count,
            "content_sha256": sha, "retry_allowed": false]
        try request.admitMutationResult(reply)
        reply["connection_epoch"] = String(repeating: "f", count: 32)
        try rejects("stale_reply") { try request.admitMutationResult(reply) }
        reply["connection_epoch"] = request.epoch; reply["retry_allowed"] = true
        try rejects("retry_reply") { try request.admitMutationResult(reply) }
        reply["retry_allowed"] = false; reply["bytes_confirmed"] = 1
        try rejects("incomplete_commit") { try request.admitMutationResult(reply) }
        var downloadArgs = args("download"); downloadArgs["size"] = bytes.count
        let download = try NASFileMutationRequest(value: downloadArgs, now: now)
        var output: [String: Any] = ["schema_version": 1, "operation": "download", "operation_id": download.operationID,
            "source_ref": download.sourceRef, "config_generation": download.generation, "connection_epoch": download.epoch,
            "object_ref": downloadArgs["object_ref"]!, "revision": downloadArgs["revision"]!, "status": "read", "failure": NSNull(),
            "transfer_kind": "inline_base64", "name": "fixture.txt", "size": bytes.count, "sha256": sha,
            "data_base64": bytes.base64EncodedString(), "downloadable_artifact": false, "delivery_code": "platform_file_publisher_required"]
        try download.admitDownloadResult(output)
        output["downloadable_artifact"] = true
        try rejects("fake_artifact") { try download.admitDownloadResult(output) }
        output["downloadable_artifact"] = false; output["url"] = "https://example.invalid/fake"
        try rejects("fake_url") { try download.admitDownloadResult(output) }
        print("PASS NAS general file DTO/attachment/result checks (offline; no registration or authority)")
    }
}
