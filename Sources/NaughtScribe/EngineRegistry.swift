import EngineSpeechTranscriber
import TranscriptionCore

/// The speech-to-text engines the app can use.
struct EngineRegistry: Sendable {
    /// The engines in the app. This array is the only place in the app that lists engines:
    /// a new engine is added here, and nothing else needs to change.
    static let shared = EngineRegistry(engines: [SpeechTranscriberEngine()])

    let engines: [any TranscriptionEngine]

    /// Creates a registry with the given engines. Tests pass fake engines here.
    init(engines: [any TranscriptionEngine]) {
        self.engines = engines
    }

    /// The engine with this identifier, or nil when there is none.
    func engine(id: String) -> (any TranscriptionEngine)? {
        engines.first { $0.descriptor.id == id }
    }

    /// All engines, the most preferred first.
    func sortedEngines() -> [any TranscriptionEngine] {
        engines.sorted { $0.descriptor.priority < $1.descriptor.priority }
    }

    /// The engine a job should use: the preferred one when it exists and can run, otherwise the most preferred
    /// engine that can run. Nil when no engine can run.
    func resolve(preferredID: String?) async -> (any TranscriptionEngine)? {
        if let preferredID, let preferred = engine(id: preferredID), await preferred.availability() == .available {
            return preferred
        }
        for engine in sortedEngines() {
            if await engine.availability() == .available {
                return engine
            }
        }
        return nil
    }
}
