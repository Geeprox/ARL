import Foundation

@main enum NASPipeLivenessTests {
    enum Failure: Error { case incorrectClassification }
    static func main() throws {
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run(); exited.waitUntilExit()
        guard !exited.isRunning else { throw Failure.incorrectClassification }
        do {
            try NASPipeLiveness.check(stopped: false, childRunning: exited.isRunning)
            throw Failure.incorrectClassification
        } catch NASRuntimeFailure.unavailable { }
        // A stop remains cancellation even if it races with child reaping.
        do {
            try NASPipeLiveness.check(stopped: true, childRunning: exited.isRunning)
            throw Failure.incorrectClassification
        } catch is CancellationError { }
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["10"]
        try running.run()
        defer { if running.isRunning { running.terminate() }; running.waitUntilExit() }
        guard running.isRunning else { throw Failure.incorrectClassification }
        try NASPipeLiveness.check(stopped: false, childRunning: running.isRunning)
        do {
            try NASPipeLiveness.check(stopped: true, childRunning: running.isRunning)
            throw Failure.incorrectClassification
        } catch is CancellationError { }
        print("NAS liveness PASS: unexpected exit is unavailable; explicit stop remains cancelled; no network, Keychain or App")
    }
}
