import Foundation
import CoreGraphics
import Vision

private struct TestGate: DeploymentGate { func verify() throws {} }
private enum TestFailure: Error { case assertion(String) }

@MainActor private final class StateBox {
    var value = MusicLoginPresentation()
    var callbacks = 0
}

@main @MainActor
enum MusicLoginPresentationTests {
    static var checks: [String] = []
    static let reference = CredentialReference(purpose: .neteaseMusic)
    // Public synthetic text only; never a real QR authentication token.
    static let url = URL(string: "https://music.163.com/login?codekey=ARL-SYNTHETIC-QR-TEST-ONLY")!

    static func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw TestFailure.assertion(name) }
        checks.append(name)
    }

    static func decode(_ image: CGImage) throws -> String? {
        let width = image.width * 8, height = image.height * 8
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TestFailure.assertion("decode_context") }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw TestFailure.assertion("decode_image") }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: scaled).perform([request])
        guard request.results?.count == 1 else { return nil }
        return request.results?.first?.payloadStringValue
    }

    static func qrChecks() throws {
        for (i, raw) in [url.absoluteString,
                        "https://music.163.com:443/login?codekey=ARL-SYNTHETIC-ONLY",
                        "https://sub.music.163.com/login?codekey=ARL-SYNTHETIC-ONLY"].enumerated() {
            guard let rendered = MusicLoginPresentation.render(URL(string: raw)!) else { throw TestFailure.assertion("qr_render") }
            try require(try decode(rendered) == raw, "qr_\(i)_independent_vision_roundtrip")
            let scaled = rendered.width * max(1, 280 / rendered.width)
            try require(scaled <= 280 && scaled % rendered.width == 0, "qr_\(i)_integral_layout")
        }
        for (i, raw) in ["http://music.163.com/login", "https://music.163.com.evil.invalid/login",
                         "file:///tmp/qr.png", "data:image/png;base64,AAAA", "https://user@music.163.com/login",
                         "https://music.163.com:8443/login", "https://music.163.com./login",
                         "https://music.163.com/login?key=" + String(repeating: "x", count: 4096)].enumerated() {
            try require(MusicLoginPresentation.render(URL(string: raw)!) == nil, "unsafe_qr_\(i)_rejected")
        }
        var state = MusicLoginPresentation()
        let first = UUID(), second = UUID(), other = CredentialReference(purpose: .neteaseMusic)
        try require(state.begin(id: first, reference: reference), "begin_explicit_request")
        try require(!state.begin(id: second, reference: reference), "overlap_blocked")
        try require(state.receive(url, id: second, reference: reference) == .ignored, "foreign_request_ignored")
        try require(state.receive(url, id: first, reference: other) == .ignored, "foreign_credential_ignored")
        try require(state.receive(url, id: first, reference: reference) == .displayed, "current_qr_displayed")
        try require(state.phase == .waitingForScan && state.image != nil, "waiting_is_not_login_success")
        try require(state.receive(url, id: first, reference: reference) == .ignored, "second_qr_does_not_replace_first")
        state.cancel()
        try require(state.image == nil && state.phase == .cancelling, "cancel_hides_qr_immediately")
        try require(!state.begin(id: second, reference: reference), "cleanup_pending_blocks_refresh")
        try require(state.receive(url, id: first, reference: reference) == .ignored, "cancelled_callback_ignored")
        state.complete(.sessionPresentUnverified, id: first, reference: reference)
        try require(state.phase == .cancelled && state.image == nil, "late_success_cannot_override_cancel")
        try require(state.begin(id: second, reference: reference), "explicit_retry_after_cleanup")
        _ = state.receive(url, id: second, reference: reference)
        state.complete(.loginExpired, id: second, reference: reference)
        try require(state.phase == .expired && state.image == nil, "expiry_clears_image")
        try require(state.phase.loginButtonTitle == "刷新二维码", "expiry_offers_manual_refresh")
        try require(state.receive(url, id: second, reference: reference) == .ignored, "expired_reply_cannot_revive_qr")

        for (i, error) in [TransportFailure.timeout as any Error, MusicLoginRuntimeFailure.expired,
                            MusicLoginRuntimeFailure.runtimeExited, CredentialError.staleReference,
                            CredentialError.storageUnavailable, MusicReadRuntimeFailure.cleanupUnproven].enumerated() {
            let id = UUID()
            _ = state.begin(id: id, reference: reference)
            _ = state.receive(url, id: id, reference: reference)
            state.fail(error, id: id, reference: reference)
            try require(state.image == nil && state.phase.message != nil && state.phase != .sessionSaved, "finite_failure_\(i)_clears_qr_without_success")
            if i == 0 { try require(state.phase == .timedOut, "timeout_is_visible_and_manual") }
        }
        let invalidID = UUID()
        _ = state.begin(id: invalidID, reference: reference)
        try require(state.receive(URL(string: "https://evil.invalid/login")!, id: invalidID, reference: reference) == .rejected, "invalid_qr_requires_runtime_cancel")
        state.cancel()
        state.fail(CancellationError(), id: invalidID, reference: reference)
        try require(state.phase == .failed(.invalidQRCode), "invalid_qr_error_survives_cleanup_cancel")

        let closedID = UUID(), freshID = UUID()
        _ = state.begin(id: closedID, reference: reference)
        _ = state.receive(url, id: closedID, reference: reference)
        state.invalidate()
        try require(state.phase == .idle && state.image == nil, "window_close_drops_presentation")
        _ = state.begin(id: freshID, reference: other)
        try require(state.receive(url, id: closedID, reference: reference) == .ignored, "old_window_callback_cannot_pollute_replacement")
        state.complete(.sessionPresentUnverified, id: closedID, reference: reference)
        state.fail(CredentialError.missing, id: closedID, reference: reference)
        try require(state.phase == .requesting, "old_terminal_replies_cannot_change_new_session")
        _ = state.receive(url, id: freshID, reference: other)
        state.complete(.credentialUnconfirmed, id: freshID, reference: other)
        try require(state.phase == .failed(.providerUnconfirmed) && state.image == nil, "provider_failure_remains_visible")
        let finalID = UUID()
        _ = state.begin(id: finalID, reference: other)
        state.complete(.sessionPresentUnverified, id: finalID, reference: other)
        try require(state.phase == .sessionSaved && state.image == nil, "confirmed_session_is_distinct_from_verified_service")

        let cleanupID = UUID()
        _ = state.begin(id: cleanupID, reference: reference)
        state.cancel()
        state.fail(MusicReadRuntimeFailure.cleanupUnproven, id: cleanupID, reference: reference)
        try require(state.phase == .failed(.cleanupUnproven), "cleanup_failure_not_hidden_by_cancel")
    }

    static func syntheticInput() throws -> CredentialInput {
        let device = try JSONSerialization.data(withJSONObject: ["deviceId": "00000000-0000-4000-8000-000000000001"])
        let encrypted = try JSONSerialization.data(withJSONObject: ["iv": String(repeating: "0", count: 32), "data": String(repeating: "0", count: 32)])
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "storage": "official", "files": [
            ".netease_mcp_device.json": device.base64EncodedString(),
            ".config/ncm-cli/credentials.enc.json": encrypted.base64EncodedString()]])
        return try CredentialInput(purpose: .neteaseMusic, data: data)
    }

    static func runtimeChecks(root: URL) async throws {
        for mode in ["success", "expired", "unconfirmed", "exited", "unsafe", "duplicate", "cancel"] {
            let box = StateBox(), id = UUID(), owner = MusicReadProcessOwner()
            _ = box.value.begin(id: id, reference: reference)
            let runtime = MusicRuntimeClient(gate: TestGate(), bundleURL: root.appendingPathComponent(mode + ".app"), processOwner: owner)
            let secret = try syntheticInput()
            defer { secret.clear() }
            let task = Task {
                try await runtime.send(secret, operation: .login) { received in
                    Task { @MainActor in
                        box.callbacks += 1
                        _ = box.value.receive(received, id: id, reference: reference)
                    }
                }
            }
            if mode == "cancel" {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while box.callbacks == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                box.value.cancel()
                task.cancel()
            }
            do {
                let result = try await task.value
                defer { result.credential.clear() }
                box.value.complete(result.state, id: id, reference: reference)
            } catch { box.value.fail(error, id: id, reference: reference) }
            // Drain a queued callback after completion; it must remain terminal.
            await Task.yield()
            let expected: MusicLoginPresentation.Phase = switch mode {
            case "success": .sessionSaved
            case "expired": .expired
            case "unconfirmed": .failed(.providerUnconfirmed)
            case "exited": .failed(.runtimeExited)
            case "unsafe", "duplicate": .failed(.protocolFailure)
            default: .cancelled
            }
            try require(box.value.phase == expected && box.value.image == nil, "actual_pipe_\(mode)_terminal_projection")
            try require(runtime.cleanupStatus().phase == .idle, "actual_pipe_\(mode)_child_reaped")
            if mode == "unsafe" { try require(box.callbacks == 0, "unsafe_pipe_qr_never_reaches_ui") }
            if mode == "cancel" { try require(box.callbacks == 1, "cancel_test_received_real_pipe_event") }
        }
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw TestFailure.assertion("fixture_argument") }
            try qrChecks()
            try await runtimeChecks(root: URL(fileURLWithPath: CommandLine.arguments[1]))
            let result: [String: Any] = ["status": "PASS", "checks": checks.count, "check_names": checks,
                "real_credentials": false, "real_provider_requests": 0, "qr_images_written": 0,
                "actual_runtime_pipe_cases": 7, "all_runtime_children_reaped": true]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        } catch {
            let failure: String
            if case TestFailure.assertion(let name) = error { failure = name } else { failure = "unexpected_test_error" }
            let result: [String: Any] = ["status": "FAIL", "failure": failure, "passed": checks]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { FileHandle.standardOutput.write(data) }
            exit(2)
        }
    }
}
