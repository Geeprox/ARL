import Foundation

// Local resource policy, not vendor API maxima. Raw responses retain their
// business fields; complete entries use local continuation within the unchanged
// 256KiB owner frame minus its header. HTTP and public frame budgets differ.
enum TravelReadLimits {
    static let aiSearchSeconds: TimeInterval = 60
    static let providerBytes = 1_048_576
    static let payloadBytes = 262_144 - 1024
}

struct ProbeRequest: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    let purpose: CredentialPurpose
    let request: URLRequest
    var remainingSeconds: TimeInterval = 10
    var requestTimeoutSeconds: TimeInterval = 8
    var responseByteLimit: Int = 65536 // Credential probes keep their original budget.
    var description: String { "ProbeRequest(\(purpose.rawValue), <redacted>)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
struct ProbeResponse: Sendable { let status: Int; let contentType: String; let body: Data }
enum TransportFailure: Error { case network, timeout, cancelled, responseLimit, redirect, protocolFailure }
protocol ProbeTransport: Sendable { func send(_ probe: ProbeRequest) async throws -> ProbeResponse }

/// No shared cache/cookies/credentials, redirects/retries, raw errors or telemetry. One bounded HTTP request per test.
struct BoundedHTTPS: ProbeTransport {
    let gate: any DeploymentGate
    var configuration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    func send(_ probe: ProbeRequest) async throws -> ProbeResponse {
        try gate.verify()
        guard TravelReadWirePolicy.allows(probe) else { throw TransportFailure.protocolFailure }
        let longAIRead: Bool
        if probe.purpose == .fliggyTravelReadOnly, let body = probe.request.httpBody,
           let root = try? MusicStrictJSON.object(body, limit: 32768),
           let params = root["params"] as? [String: Any] {
            longAIRead = params["name"] as? String == FlyAIReadTool.aiSearch.rawValue
        } else { longAIRead = false }
        let maximum = longAIRead ? TravelReadLimits.aiSearchSeconds : 10
        guard probe.remainingSeconds.isFinite, probe.remainingSeconds > 0, probe.remainingSeconds <= maximum,
              probe.requestTimeoutSeconds.isFinite, probe.requestTimeoutSeconds > 0,
              probe.requestTimeoutSeconds <= (longAIRead ? maximum : 8)
        else { throw TransportFailure.timeout }
        guard (1...TravelReadLimits.providerBytes).contains(probe.responseByteLimit) else { throw TransportFailure.responseLimit }
        let operation = HTTPTransaction(configuration: configuration, remainingSeconds: probe.remainingSeconds, requestTimeoutSeconds: min(probe.requestTimeoutSeconds, probe.remainingSeconds), flyAIRequestID: probe.purpose == .fliggyTravelReadOnly ? 1 : nil, responseByteLimit: probe.responseByteLimit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in operation.begin(probe.request, continuation: continuation) }
        } onCancel: { operation.cancel() }
    }
}
private final class HTTPTransaction: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: @Sendable () -> URLSessionConfiguration
    private let remainingSeconds: TimeInterval
    private let requestTimeoutSeconds: TimeInterval
    private let flyAIRequestID: Int?
    private let responseByteLimit: Int
    init(configuration: @escaping @Sendable () -> URLSessionConfiguration, remainingSeconds: TimeInterval, requestTimeoutSeconds: TimeInterval, flyAIRequestID: Int?, responseByteLimit: Int) { self.configuration = configuration; self.remainingSeconds = remainingSeconds; self.requestTimeoutSeconds = requestTimeoutSeconds; self.flyAIRequestID = flyAIRequestID; self.responseByteLimit = responseByteLimit; super.init() }
    private var continuation: CheckedContinuation<ProbeResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var cancelled = false
    private var finished = false
    func begin(_ request: URLRequest, continuation: CheckedContinuation<ProbeResponse, any Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: TransportFailure.cancelled); return }
        self.continuation = continuation
        let config = configuration()
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeoutSeconds; config.timeoutIntervalForResource = remainingSeconds
        config.waitsForConnectivity = false; config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var bounded = request; bounded.timeoutInterval = requestTimeoutSeconds; bounded.cachePolicy = .reloadIgnoringLocalCacheData
        task = session?.dataTask(with: bounded); let pending = task
        lock.unlock(); pending?.resume()
    }
    func cancel() { lock.withLock { cancelled = true }; complete(.failure(TransportFailure.cancelled)) }
    private func complete(_ result: Result<ProbeResponse, any Error>) {
        lock.lock()
        guard !finished, continuation != nil else { lock.unlock(); return }
        finished = true; let c = continuation; continuation = nil; let s = session; let t = task
        session = nil; task = nil; body.removeAll(keepingCapacity: false)
        lock.unlock(); t?.cancel(); s?.invalidateAndCancel(); c?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil); complete(.failure(TransportFailure.redirect)) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let r = response as? HTTPURLResponse, r.expectedContentLength <= responseByteLimit else { completionHandler(.cancel); complete(.failure(TransportFailure.responseLimit)); return }
        lock.withLock { self.response = r }; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let outcome = lock.withLock { () -> Result<ProbeResponse?, any Error> in
            guard !finished else { return .success(nil) }
            guard body.count + data.count <= responseByteLimit else { return .failure(TransportFailure.responseLimit) }
            body.append(data)
            guard let flyAIRequestID, let response, response.statusCode == 200,
                  response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream" else { return .success(nil) }
            do {
                guard let matched = try FlyAIMCPResponse.matchingFrame(body, requestID: flyAIRequestID, complete: false, byteLimit: responseByteLimit) else { return .success(nil) }
                return .success(.init(status: response.statusCode, contentType: "application/json", body: matched))
            } catch let failure as FlyAIResponseFailure { return .failure(failure) }
            catch { return .failure(TransportFailure.protocolFailure) }
        }
        switch outcome {
        case .success(let matched): if let matched { complete(.success(matched)) }
        case .failure(let failure): complete(.failure(failure))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let e = error as? URLError {
            complete(.failure(e.code == .timedOut ? TransportFailure.timeout : e.code == .cancelled ? TransportFailure.cancelled : TransportFailure.network)); return
        }
        if error != nil { complete(.failure(TransportFailure.network)); return }
        let result = lock.withLock { response.map { ProbeResponse(status: $0.statusCode, contentType: $0.value(forHTTPHeaderField: "Content-Type") ?? "", body: body) } }
        guard let result else { complete(.failure(TransportFailure.protocolFailure)); return }
        complete(.success(result))
    }
}
