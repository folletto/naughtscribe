import Foundation

/// Builds the streams that engines return from `prepare(_:)` and `transcribe(_:)`.
public enum TranscriptionStream {
    /// Creates a stream whose events come from `work`, which runs in its own task. The stream finishes when `work`
    /// returns. When `work` throws, the stream fails with `.cancelled` if its task was cancelled, and otherwise with
    /// `TranscriptionError.normalize(_:)`. Ending iteration, or cancelling the consumer, cancels the work.
    public static func make<Element: Sendable>(
        _ work: @escaping @Sendable (AsyncThrowingStream<Element, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await work(continuation)
                    continuation.finish()
                } catch {
                    let failure = Task.isCancelled ? TranscriptionError.cancelled : TranscriptionError.normalize(error)
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
