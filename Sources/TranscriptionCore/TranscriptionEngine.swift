import Foundation

/// A speech-to-text engine. Each engine lives in its own target and depends only on `TranscriptionCore`.
public protocol TranscriptionEngine: Sendable {
    /// Identity and ordering of this engine.
    var descriptor: EngineDescriptor { get }

    /// Cheap check of hardware and OS support. Never downloads anything.
    func availability() async -> EngineAvailability

    /// Languages this engine can transcribe.
    func languageSupport() async -> LanguageSupport

    /// Models the user can choose from. An engine with one built-in model returns a single entry.
    func models() async -> [ModelDescriptor]

    /// Whether the model for `selection` is ready, needs a download, or cannot run.
    func modelState(for selection: ModelSelection) async -> ModelState

    /// Downloads and installs the model for `selection`. Yields progress from 0 to 1, then finishes.
    /// Cancelling the consumer cancels the download.
    func prepare(_ selection: ModelSelection) -> AsyncThrowingStream<Double, Error>

    /// Runs one job, downloading the model first if needed (reported as `.phase(.downloadingModel)`).
    /// Ends with exactly one `.finished` event, which is the last event before the stream finishes.
    /// Errors are `TranscriptionError` values. Cancelling the consumer cancels the work.
    func transcribe(_ request: TranscriptionRequest) -> AsyncThrowingStream<TranscriptionEvent, Error>
}

/// Identity and ordering of an engine.
public struct EngineDescriptor: Sendable, Hashable {
    /// Stable identifier that is persisted, for example `"apple.speechtranscriber"`.
    public let id: String
    /// User-facing name.
    public let name: String
    /// One user-facing sentence describing the engine.
    public let summary: String
    /// Lower values are preferred when the app picks an engine automatically.
    public let priority: Int

    /// Creates a descriptor.
    public init(id: String, name: String, summary: String, priority: Int) {
        self.id = id
        self.name = name
        self.summary = summary
        self.priority = priority
    }
}

/// Whether an engine can run on this Mac.
public enum EngineAvailability: Sendable, Equatable {
    /// The engine can run.
    case available
    /// The engine cannot run. `reason` is a user-facing sentence.
    case unavailable(reason: String)
}

/// Languages an engine can transcribe.
public struct LanguageSupport: Sendable, Equatable {
    /// Locales the engine can transcribe.
    public let locales: [Locale]
    /// Whether the engine can detect the spoken language itself.
    public let supportsAutoDetect: Bool

    /// Creates a language support description.
    public init(locales: [Locale], supportsAutoDetect: Bool) {
        self.locales = locales
        self.supportsAutoDetect = supportsAutoDetect
    }
}

/// A model an engine can use.
public struct ModelDescriptor: Sendable, Hashable, Identifiable {
    /// Stable identifier, passed back in `ModelSelection.modelID`.
    public let id: String
    /// User-facing name.
    public let name: String
    /// Download size in bytes, or nil when unknown or managed by the system.
    public let downloadSizeBytes: Int64?
    /// Languages this model supports, or nil for every language the engine supports.
    public let locales: [Locale]?

    /// Creates a model descriptor.
    public init(id: String, name: String, downloadSizeBytes: Int64?, locales: [Locale]?) {
        self.id = id
        self.name = name
        self.downloadSizeBytes = downloadSizeBytes
        self.locales = locales
    }
}

/// Whether a model can be used for a selection right now.
public enum ModelState: Sendable, Equatable {
    /// The model is installed and can run.
    case ready
    /// The model must be downloaded first. `bytes` is nil when the size is unknown.
    case needsDownload(bytes: Int64?)
    /// The engine cannot run this selection.
    case unsupported
}
