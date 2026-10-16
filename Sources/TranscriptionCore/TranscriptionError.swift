import Foundation

/// Failures that a transcription engine or the audio decoder reports. `errorDescription` is user-facing.
public enum TranscriptionError: LocalizedError, Equatable, Sendable {
    /// The engine cannot run on this Mac. The value is a user-facing sentence.
    case engineUnavailable(String)
    /// The language is not supported. The value is the language's display name.
    case unsupportedLanguage(String)
    /// The file could not be read as audio. The value is the file name.
    case cannotOpenFile(String)
    /// The file is a media file without an audio track.
    case noAudioTrack
    /// The model could not be downloaded. The value is the detail.
    case modelDownloadFailed(String)
    /// The model is not installed. The value is the model name.
    case modelMissing(String)
    /// The engine failed. The value is the detail.
    case engineFailed(String)
    /// The job was cancelled.
    case cancelled

    /// A short, user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let reason):
            return reason
        case .unsupportedLanguage(let language):
            return "Speech recognition does not support \(language) on this Mac."
        case .cannotOpenFile(let name):
            return "“\(name)” could not be opened as an audio file."
        case .noAudioTrack:
            return "The file does not contain an audio track."
        case .modelDownloadFailed(let detail):
            return "The model could not be downloaded: \(detail)"
        case .modelMissing(let name):
            return "The model “\(name)” is not installed."
        case .engineFailed(let detail):
            return "Transcription failed: \(detail)"
        case .cancelled:
            return "Transcription was cancelled."
        }
    }

    /// Maps any error to a `TranscriptionError`. A `TranscriptionError` is returned as is,
    /// `CancellationError` becomes `.cancelled`, and anything else becomes `.engineFailed`.
    public static func normalize(_ error: Error) -> TranscriptionError {
        switch error {
        case let transcriptionError as TranscriptionError:
            return transcriptionError
        case is CancellationError:
            return .cancelled
        default:
            return .engineFailed(String(describing: error))
        }
    }
}
