import Foundation
import Synchronization
import TranscriptionCore

/// A transcription engine for tests. It records every request it receives and plays back scripted events.
final class FakeEngine: TranscriptionEngine {
    /// What one `transcribe` call does: it yields `events` in order, then throws `error` if there is one.
    struct Script: Sendable {
        var events: [TranscriptionEvent] = []
        var error: (any Error)?
        /// A pause before each event, so a test can look at or cancel a job while it runs.
        var delay: Duration?
    }

    private struct State: Sendable {
        var requests: [TranscriptionRequest] = []
        var cancelledCount = 0
    }

    let descriptor: EngineDescriptor
    private let availabilityResult: EngineAvailability
    private let scripts: [Script]
    private let state = Mutex(State())

    /// - Parameter scripts: The script for each `transcribe` call, in order. Calls past the last script reuse it.
    init(
        id: String = "fake.engine",
        priority: Int = 0,
        availability: EngineAvailability = .available,
        scripts: [Script] = [Script()]
    ) {
        descriptor = EngineDescriptor(id: id, name: "Fake engine \(id)", summary: "A test engine.", priority: priority)
        availabilityResult = availability
        self.scripts = scripts.isEmpty ? [Script()] : scripts
    }

    /// Every request received so far, in order.
    var requests: [TranscriptionRequest] {
        state.withLock { $0.requests }
    }

    /// How many streams the consumer cancelled before they ended.
    var cancelledRequests: Int {
        state.withLock { $0.cancelledCount }
    }

    func availability() async -> EngineAvailability {
        availabilityResult
    }

    func languageSupport() async -> LanguageSupport {
        LanguageSupport(locales: [Locale(identifier: "en-US")], supportsAutoDetect: false)
    }

    func models() async -> [ModelDescriptor] {
        [ModelDescriptor(id: "fake-model", name: "Fake model", downloadSizeBytes: nil, locales: nil)]
    }

    func modelState(for selection: ModelSelection) async -> ModelState {
        .ready
    }

    func prepare(_ selection: ModelSelection) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(1)
            continuation.finish()
        }
    }

    func transcribe(_ request: TranscriptionRequest) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let script = state.withLock { recorded -> Script in
            let index = min(recorded.requests.count, scripts.count - 1)
            recorded.requests.append(request)
            return scripts[index]
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for event in script.events {
                        if let delay = script.delay {
                            try await Task.sleep(for: delay)
                        }
                        continuation.yield(event)
                    }
                    if let error = script.error {
                        throw error
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    self.state.withLock { $0.cancelledCount += 1 }
                }
                task.cancel()
            }
        }
    }
}
