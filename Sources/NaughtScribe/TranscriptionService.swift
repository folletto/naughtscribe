import AVFoundation
import CoreMedia
import Foundation
import Speech

/// One report from `TranscriptionService.transcribe(fileURL:locale:)`.
struct TranscriptionUpdate: Sendable {
    /// Fraction of the job completed, from 0 to 1.
    let progress: Double
    /// Short, user-facing description of the current step.
    let statusMessage: String
    /// The full transcript. Set only on the final update, where `progress` is 1.0.
    let text: String?

    init(progress: Double, statusMessage: String, text: String? = nil) {
        self.progress = progress
        self.statusMessage = statusMessage
        self.text = text
    }
}

enum TranscriptionError: LocalizedError {
    case unsupportedLanguage(String)
    case noAudioTrack
    case cannotOpenFile(String)
    /// Part of the error vocabulary for audio conversion. `TranscriptionService` does not throw it,
    /// because `SpeechAnalyzer` converts file input to the module's format itself.
    case cannotCreateConverter
    case analysisFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language):
            return "Speech recognition does not support \(language) on this Mac."
        case .noAudioTrack:
            return "The file does not contain an audio track."
        case .cannotOpenFile(let name):
            return "“\(name)” could not be opened as an audio file."
        case .cannotCreateConverter:
            return "The audio could not be converted to a format the speech engine accepts."
        case .analysisFailed(let detail):
            return "Transcription failed: \(detail)"
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}

/// Lifecycle state of a transcript, for the transcript model to store and display.
enum TranscriptionStatus: String, Codable, Sendable {
    case queued
    case downloadingModel
    case transcribing
    case completed
    case failed
    case cancelled
}

struct TranscriptionService: Sendable {
    private typealias Continuation = AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation

    /// Transcribes an audio file on-device. The stream yields progress updates, then one final update
    /// with progress 1.0 and the full text, then finishes. Cancelling the consuming task cancels the work.
    func transcribe(fileURL: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(fileURL: fileURL, locale: locale, continuation: continuation)
                    continuation.finish()
                } catch {
                    let failure = Task.isCancelled ? TranscriptionError.cancelled : Self.normalize(error)
                    continuation.finish(throwing: failure)
                }
            }
            // Ending iteration, or cancelling the consumer, terminates the stream and cancels the work.
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func run(fileURL: URL, locale: Locale, continuation: Continuation) async throws {
        // Files chosen by the user in this sandboxed app are security-scoped; access must stay open while reading.
        let startedScopedAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if startedScopedAccess { fileURL.stopAccessingSecurityScopedResource() }
        }

        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.analysisFailed("Speech transcription is not available on this device.")
        }
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLanguage(displayName(for: locale))
        }

        let audioFile = try await openAudioFile(at: fileURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalSeconds = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0

        // Final results only. Each result carries its audio time range, which drives progress.
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await ensureModelInstalled(for: transcriber, locale: resolvedLocale, continuation: continuation)
        try Task.checkCancellation()

        let reservedHere = try await reserveLocale(resolvedLocale)
        let text: String
        do {
            text = try await analyze(
                audioFile: audioFile,
                transcriber: transcriber,
                totalSeconds: totalSeconds,
                continuation: continuation
            )
        } catch {
            if reservedHere { await AssetInventory.release(reservedLocale: resolvedLocale) }
            throw error
        }
        if reservedHere { await AssetInventory.release(reservedLocale: resolvedLocale) }

        continuation.yield(TranscriptionUpdate(progress: 1.0, statusMessage: "Done", text: text))
    }

    private static func openAudioFile(at url: URL) async throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            // AVAudioFile rejects both non-audio files and media files with no audio track. Asking the
            // asset tells them apart, so the user gets the more specific message when it applies.
            if let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio), tracks.isEmpty {
                throw TranscriptionError.noAudioTrack
            }
            throw TranscriptionError.cannotOpenFile(url.lastPathComponent)
        }
    }

    private static func ensureModelInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        continuation: Continuation
    ) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed {
            return
        }
        if status == .unsupported {
            throw TranscriptionError.unsupportedLanguage(displayName(for: locale))
        }

        continuation.yield(TranscriptionUpdate(progress: 0, statusMessage: "Downloading language model"))
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.analysisFailed(String(describing: error))
        }
    }

    /// Reserves the locale's assets for this app. Returns true only if this call made the reservation,
    /// which is the only case in which the caller should release it.
    private static func reserveLocale(_ locale: Locale) async throws -> Bool {
        do {
            return try await AssetInventory.reserve(locale: locale)
        } catch {
            throw TranscriptionError.analysisFailed(String(describing: error))
        }
    }

    private static func analyze(
        audioFile: AVAudioFile,
        transcriber: SpeechTranscriber,
        totalSeconds: Double,
        continuation: Continuation
    ) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Results arrive while the analyzer reads the file, so they are collected in a separate task.
        // The sequence is taken before analysis starts so that no early result is missed.
        let results = transcriber.results
        let resultsTask = Task<String, Error> {
            var segments: [String] = []
            for try await result in results where result.isFinal {
                let segment = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    segments.append(segment)
                }
                let fraction = totalSeconds > 0 ? result.range.end.seconds / totalSeconds : 0
                continuation.yield(
                    TranscriptionUpdate(progress: Self.clampedProgress(fraction), statusMessage: "Transcribing")
                )
            }
            return segments.joined(separator: " ")
        }

        do {
            continuation.yield(TranscriptionUpdate(progress: 0, statusMessage: "Transcribing"))
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                // Cancelling the analyzer ends the results stream, so the results task then completes.
                resultsTask.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
            let text = try await resultsTask.value
            try Task.checkCancellation()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await analyzer.cancelAndFinishNow()
            // When the analyzer fails, the results stream fails with the underlying cause, while the
            // analysis call may only report cancellation. Prefer the real error.
            if case .failure(let resultsError) = await resultsTask.result, !(resultsError is CancellationError) {
                throw resultsError
            }
            throw error
        }
    }

    private static func clampedProgress(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 0.99)
    }

    private static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private static func normalize(_ error: Error) -> TranscriptionError {
        switch error {
        case let transcriptionError as TranscriptionError:
            return transcriptionError
        case is CancellationError:
            return .cancelled
        default:
            return .analysisFailed(String(describing: error))
        }
    }
}
