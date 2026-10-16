import Foundation

/// The language a job should transcribe in.
public enum LanguageChoice: Sendable, Hashable {
    /// The engine detects the language, or falls back to the system language if it cannot.
    case automatic
    /// A specific language.
    case specific(Locale)
}

/// Which model and language a job or a download is for.
public struct ModelSelection: Sendable, Hashable {
    /// Model identifier, or nil for the engine's default model.
    public var modelID: String?
    /// The language to transcribe in.
    public var language: LanguageChoice

    /// Creates a selection.
    public init(modelID: String?, language: LanguageChoice) {
        self.modelID = modelID
        self.language = language
    }
}

/// One transcription job.
public struct TranscriptionRequest: Sendable {
    /// Audio or video file to transcribe. The file must be readable when the job runs.
    /// The app manages security-scoped access.
    public let fileURL: URL
    /// The model and language to use.
    public let selection: ModelSelection

    /// Creates a request.
    public init(fileURL: URL, selection: ModelSelection) {
        self.fileURL = fileURL
        self.selection = selection
    }
}

/// The step a running job is in.
public enum TranscriptionPhase: Sendable, Equatable {
    /// Reading and converting the audio.
    case preparingAudio
    /// Downloading the model.
    case downloadingModel
    /// Loading the installed model.
    case loadingModel
    /// Recognizing speech.
    case transcribing
}

/// A span of recognized text.
public struct TranscriptSegment: Codable, Sendable, Hashable {
    /// The recognized text.
    public let text: String
    /// Start time in seconds from the start of the audio, when the engine reports it.
    public let start: TimeInterval?
    /// End time in seconds from the start of the audio, when the engine reports it.
    public let end: TimeInterval?

    /// Creates a segment.
    public init(text: String, start: TimeInterval?, end: TimeInterval?) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The finished transcript of one job.
public struct TranscriptionResult: Sendable, Equatable {
    /// Recognized segments in audio order.
    public let segments: [TranscriptSegment]
    /// The language the engine detected or used, when known.
    public let detectedLanguage: Locale?
    /// The `id` of the engine that produced the transcript.
    public let engineID: String
    /// The model that produced the transcript, when the engine has models.
    public let modelID: String?

    /// Creates a result.
    public init(segments: [TranscriptSegment], detectedLanguage: Locale?, engineID: String, modelID: String?) {
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.engineID = engineID
        self.modelID = modelID
    }

    /// Segment texts joined with single spaces, trimmed.
    public var text: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Progress reported while a job runs. The last event is always `.finished`.
public enum TranscriptionEvent: Sendable {
    /// The job moved to a new step.
    case phase(TranscriptionPhase)
    /// Fraction of the job completed, from 0 to 1.
    case progress(Double)
    /// A recognized segment, in audio order.
    case segment(TranscriptSegment)
    /// The full transcript. The last event before the stream finishes.
    case finished(TranscriptionResult)
}
