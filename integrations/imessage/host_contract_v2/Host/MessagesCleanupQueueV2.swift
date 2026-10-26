import Foundation

/// Serialize owned backend stop effects. A newer native epoch may be admitted during an await;
/// its stop still waits for the older stop to exit, so no old private cleanup can outlive completion.
@MainActor final class MessagesCleanupQueueV2 {
    private var tail: Task<MessagesJSON, Error>?
    func enqueue(_ operation: @escaping @MainActor () async throws -> MessagesJSON) -> Task<MessagesJSON, Error> {
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            return try await operation()
        }
        tail = task
        return task
    }
}
