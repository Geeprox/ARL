import CoreImage
import Foundation

/// Ephemeral presentation only. The official CLI supplies QR contents, not an
/// image URL. Never fetch, open, log, persist or expose those contents to AX.
@MainActor
struct MusicLoginPresentation {
    enum Failure: Equatable {
        case invalidQRCode, providerUnconfirmed, runtimeExited, runtimeUnavailable
        case credentialsChanged, busy, cleanupUnproven, localStorage, protocolFailure
        case diagnostic(MusicDiagnostic)

        var message: String {
            switch self {
            case .diagnostic(let detail): detail.message
            case .invalidQRCode: ("登录码无效，请重新取码" + "\n" + "网易云返回的二维码内容无效或无法显示，已停止本次等待。请手动重试。")
            case .providerUnconfirmed: ("网易云未确认本次登录结果（provider_unconfirmed）。请稍后手动重试；未记录为登录成功。")
            case .runtimeExited: ("登录中断，结果未确认" + "\n" + "网易云登录程序未正常结束（runtime_exited），未确认登录。请手动重试。")
            case .runtimeUnavailable: ("登录连接未通过检查" + "\n" + "应用接入尚未完成或身份校验未通过，无法开始网易云登录。")
            case .credentialsChanged: ("密钥已变，请重新取码" + "\n" + "本机密钥已变化，本次扫码已结束。请使用当前服务密钥重新扫码。")
            case .busy: ("已有操作正在进行" + "\n" + "网易云已有操作正在进行；请等待或在原面板取消。")
            case .cleanupUnproven: ("上一次网易云连接仍在结束；完成清理前无法开始新操作。请稍后重试。")
            case .localStorage: ("保存结果未确认，请先核对状态" + "\n" + "网易云登录的本地保存或运行操作未完成，未确认登录。请检查当前状态后手动重试。")
            case .protocolFailure: ("登录结果未确认" + "\n" + "网易云登录未完成或返回内容未通过校验，未确认登录。请手动重试。")
            }
        }
    }
    enum Phase: Equatable {
        case idle, requesting, waitingForScan, cancelling, cancelled
        case expired, timedOut, sessionSaved, failed(Failure)

        var message: String? {
            switch self {
            case .idle, .requesting, .waitingForScan, .cancelling: nil
            case .cancelled: ("已取消扫码等待" + "\n" + "已取消本次扫码等待；未自动创建新的二维码。")
            case .expired: ("登录码已过期，请重新取码" + "\n" + "网易云报告二维码已过期。请点击“重新取码”重新获取。")
            case .timedOut: ("等待超时，请重新取码" + "\n" + "本次扫码等待已超时。请点击“重新取码”重新获取；未自动重试。")
            case .sessionSaved: ("登录已保存，服务待验证" + "\n" + "网易云已确认登录并保存会话；服务调用仍待验证，可点击“检查登录”。")
            case .failed(let failure): failure.message
            }
        }
        var loginButtonExplanation: String {
            switch self {
            case .expired, .timedOut: "重新获取本次登录二维码"
            case .cancelled, .failed: "重新获取本次登录二维码"
            case .sessionSaved: "重新扫码登录网易云音乐"
            default: "用网易云音乐App扫码并确认"
            }
        }
        var loginButtonTitle: String {
            switch self {
            case .expired, .timedOut: "重新取码"
            case .cancelled, .failed: "重新取码"
            case .sessionSaved: "重新登录"
            default: "扫码登录"
            }
        }
    }
    enum QRReceipt { case displayed, rejected, ignored }

    private(set) var phase: Phase = .idle
    private(set) var image: CGImage?
    private var requestID: UUID?
    private var reference: CredentialReference?

    // Refuse overlapping requests, including while cancellation is cleaning up.
    @discardableResult
    mutating func begin(id: UUID, reference: CredentialReference) -> Bool {
        guard requestID == nil, reference.purpose == .neteaseMusic else { return false }
        self.requestID = id
        self.reference = reference
        image = nil
        phase = .requesting
        return true
    }

    mutating func receive(_ url: URL, id: UUID, reference: CredentialReference) -> QRReceipt {
        guard matches(id, reference), phase == .requesting else { return .ignored }
        guard let rendered = Self.render(url) else {
            image = nil
            phase = .failed(.invalidQRCode)
            return .rejected
        }
        image = rendered
        phase = .waitingForScan
        return .displayed
    }

    mutating func cancel() {
        image = nil
        guard requestID != nil else { return }
        // Preserve a rendering failure while its runtime is being cancelled.
        if phase != .failed(.invalidQRCode) { phase = .cancelling }
    }

    /// Closing the panel or replacing credentials invalidates all queued replies.
    /// The panel separately retains the task until the SDK proves child cleanup.
    mutating func invalidate() { self = Self() }

    mutating func complete(_ state: ConnectionState, id: UUID, reference: CredentialReference) {
        guard matches(id, reference) else { return }
        let result: Phase = switch state {
        case .sessionPresentUnverified: .sessionSaved
        case .loginExpired: .expired
        default: .failed(.providerUnconfirmed)
        }
        finish(result)
    }

    mutating func fail(_ error: any Error, id: UUID, reference: CredentialReference) {
        guard matches(id, reference) else { return }
        let result: Phase
        if error is CancellationError { result = .cancelled }
        else if let error=error as? MusicDiagnosticFailure { result = .failed(.diagnostic(error.diagnostic)) }
        else if let error = error as? MusicLoginRuntimeFailure {
            result = error == .expired ? .expired : .failed(.runtimeExited)
        } else if error as? MusicReadRuntimeFailure == .cleanupUnproven { result = .failed(.cleanupUnproven) }
        else if error as? TransportFailure == .timeout { result = .timedOut }
        else {
            result = switch error as? CredentialError {
            case .deploymentNotApproved, .identityMismatch: .failed(.runtimeUnavailable)
            case .staleReference, .missing: .failed(.credentialsChanged)
            case .busy: .failed(.busy)
            case .storageUnavailable: .failed(.localStorage)
            default: .failed(.protocolFailure)
            }
        }
        finish(result)
    }

    private func matches(_ id: UUID, _ reference: CredentialReference) -> Bool {
        requestID == id && self.reference == reference
    }

    private mutating func finish(_ result: Phase) {
        image = nil
        requestID = nil
        reference = nil
        // A late success cannot override a user cancellation or rejected QR.
        // Cleanup failures must remain visible even after cancellation.
        if result == .failed(.cleanupUnproven) { phase = result }
        else if phase == .cancelling { phase = .cancelled }
        else if phase != .failed(.invalidQRCode) { phase = result }
    }

    static func render(_ url: URL) -> CGImage? {
        guard let safe = MusicLoginURL.validated(url) else { return nil }
        return autoreleasepool {
            var bytes = Data(safe.absoluteString.utf8)
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
            filter.setValue(bytes, forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let qr = filter.outputImage, !qr.extent.isEmpty,
                  qr.extent.width == qr.extent.height, qr.extent.width <= 185 else { return nil }
            // Add a four-module white quiet zone on every edge. Keep one pixel
            // per module here; the view uses integral point scaling, no blur.
            let bounds = CGRect(x: 0, y: 0, width: qr.extent.width + 8, height: qr.extent.height + 8)
            let background = CIImage(color: .white).cropped(to: bounds)
            let bordered = qr.transformed(by: .init(translationX: 4 - qr.extent.minX, y: 4 - qr.extent.minY))
                .composited(over: background)
            let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
            return context.createCGImage(bordered, from: bounds)
        }
    }
}
