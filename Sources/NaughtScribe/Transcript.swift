import Foundation

enum TranscriptStatus: String, Codable {
    case inProgress
    case done
    case failed
}

/// One transcription job and its result. Persisted as JSON by `TranscriptStore`.
struct Transcript: Codable, Identifiable, Hashable, Sendable {
    /// Immutable: the store names the file after it.
    let id: UUID
    /// Immutable: the store sorts by it.
    let createdAt: Date
    var sourceFileName: String
    /// BCP-47 language tag, for example "en-US".
    var languageIdentifier: String
    var status: TranscriptStatus
    /// 0...1. Only meaningful while `status` is `.inProgress`.
    var progress: Double
    /// Short description of the current step, for example "Preparing audio".
    var statusMessage: String
    var text: String
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceFileName: String,
        languageIdentifier: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceFileName = sourceFileName
        self.languageIdentifier = languageIdentifier
        self.status = .inProgress
        self.progress = 0
        self.statusMessage = "Preparing audio"
        self.text = ""
        self.errorMessage = nil
    }

    var title: String { sourceFileName }
}
