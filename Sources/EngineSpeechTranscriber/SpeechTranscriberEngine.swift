import AVFoundation
import CoreMedia
import Foundation
import Speech
import TranscriptionCore

/// Transcribes files on-device with Apple's speech model, through `SpeechAnalyzer`. Needs a Mac with Apple silicon.
public struct SpeechTranscriberEngine: TranscriptionEngine {
    public let descriptor = EngineDescriptor(
        id: "apple.speechtranscriber",
        name: "Apple Speech",
        summary: "Apple’s on-device speech model. Requires a Mac with Apple silicon.",
        priority: 0
    )

    /// The only model this engine offers. The system manages the actual assets, one set per language.
    private static let modelID = "default"
    private static let unavailableReason = "Apple Speech is not available on this Mac. It requires Apple silicon."

    private typealias EventContinuation = AsyncThrowingStream<TranscriptionEvent, Error>.Continuation

    public init() {}

    public func availability() async -> EngineAvailability {
        SpeechTranscriber.isAvailable ? .available : .unavailable(reason: Self.unavailableReason)
    }

    public func languageSupport() async -> LanguageSupport {
        LanguageSupport(locales: await SpeechTranscriber.supportedLocales, supportsAutoDetect: false)
    }

    /// The one model. `ModelSelection.modelID` is therefore not used.
    public func models() async -> [ModelDescriptor] {
        [ModelDescriptor(id: Self.modelID, name: "Default", downloadSizeBytes: nil, locales: nil)]
    }

    public func modelState(for selection: ModelSelection) async -> ModelState {
        let requested = Self.requestedLocale(for: selection.language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            return .unsupported
        }
        switch await AssetInventory.status(forModules: [Self.makeTranscriber(locale: locale)]) {
        case .installed:
            return .ready
        case .unsupported:
            return .unsupported
        default:
            // `.supported` and `.downloading` both still need the download. Its size is not known before it starts.
            return .needsDownload(bytes: nil)
        }
    }

    public func prepare(_ selection: ModelSelection) -> AsyncThrowingStream<Double, Error> {
        Self.makeStream { continuation in
            try await Self.install(selection, continuation: continuation)
        }
    }

    public func transcribe(_ request: TranscriptionRequest) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        Self.makeStream { continuation in
            try await self.run(request, continuation: continuation)
        }
    }

    // MARK: - Jobs

    /// Runs one job and yields its events. The last event is `.finished`.
    private func run(_ request: TranscriptionRequest, continuation: EventContinuation) async throws {
        continuation.yield(.phase(.preparingAudio))
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.engineUnavailable(Self.unavailableReason)
        }
        let requested = Self.requestedLocale(for: request.selection.language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.unsupportedLanguage(Self.displayName(for: requested))
        }

        let audioFile = try await Self.openAudioFile(at: request.fileURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalSeconds = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0

        let transcriber = Self.makeTranscriber(locale: locale)
        try await Self.ensureModelInstalled(for: transcriber, locale: locale, continuation: continuation)
        try Task.checkCancellation()

        // `reserve` reports whether this call made the reservation. Only that reservation is released here.
        let reservedHere = try await AssetInventory.reserve(locale: locale)
        let segments: [TranscriptSegment]
        do {
            segments = try await Self.analyze(
                audioFile: audioFile,
                transcriber: transcriber,
                totalSeconds: totalSeconds,
                continuation: continuation
            )
        } catch {
            if reservedHere { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
        if reservedHere { await AssetInventory.release(reservedLocale: locale) }

        continuation.yield(.finished(TranscriptionResult(
            segments: segments,
            detectedLanguage: nil,
            engineID: descriptor.id,
            modelID: Self.modelID
        )))
    }

    // MARK: - Model

    /// Downloads the model when it is not installed. Yields `.phase(.downloadingModel)` only when a download is needed.
    private static func ensureModelInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        continuation: EventContinuation
    ) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw TranscriptionError.unsupportedLanguage(displayName(for: locale))
        default:
            // The model is missing, or is still being downloaded by the system.
            continuation.yield(.phase(.downloadingModel))
            try await downloadModel(for: transcriber)
        }
    }

    /// Yields 0, downloads the model when it is missing, yields the download's progress, then yields 1.
    private static func install(
        _ selection: ModelSelection,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.engineUnavailable(unavailableReason)
        }
        let requested = requestedLocale(for: selection.language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.unsupportedLanguage(displayName(for: requested))
        }
        continuation.yield(0)
        try await downloadModel(for: makeTranscriber(locale: locale)) { fraction in
            continuation.yield(fraction)
        }
        continuation.yield(1)
    }

    /// Downloads and installs whatever the transcriber is missing. `onProgress` receives the download's fraction
    /// completed. A failure becomes `.modelDownloadFailed`. A cancelled download also fails here, and the stream
    /// then reports `.cancelled`, because its task is cancelled.
    private static func downloadModel(
        for transcriber: SpeechTranscriber,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                return
            }
            // The system reports the download through a Foundation `Progress`, observed until the download ends.
            let observation = onProgress.map { report in
                request.progress.observe(\.fractionCompleted) { progress, _ in
                    report(min(max(progress.fractionCompleted, 0), 1))
                }
            }
            defer { observation?.invalidate() }
            try await request.downloadAndInstall()
        } catch {
            throw TranscriptionError.modelDownloadFailed(String(describing: error))
        }
    }

    // MARK: - Analysis

    /// Feeds the file to the analyzer and returns the final segments in audio order. Each segment and each
    /// progress value is yielded as its result arrives.
    private static func analyze(
        audioFile: AVAudioFile,
        transcriber: SpeechTranscriber,
        totalSeconds: Double,
        continuation: EventContinuation
    ) async throws -> [TranscriptSegment] {
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Results arrive while the analyzer reads the file, so they are collected in a separate task.
        // The sequence is taken before analysis starts so that no early result is missed.
        let results = transcriber.results
        let resultsTask = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let segment = TranscriptSegment(
                        text: text,
                        start: Self.seconds(result.range.start),
                        end: Self.seconds(result.range.end)
                    )
                    segments.append(segment)
                    continuation.yield(.segment(segment))
                }
                let fraction = totalSeconds > 0 ? result.range.end.seconds / totalSeconds : 0
                continuation.yield(.progress(Self.clampedProgress(fraction)))
            }
            return segments
        }

        do {
            continuation.yield(.phase(.transcribing))
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
            let segments = try await resultsTask.value
            try Task.checkCancellation()
            return segments
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

    // MARK: - Helpers

    /// Creates a stream whose events come from `work`, which runs in its own task. The stream finishes when `work`
    /// returns, and fails with the error from `TranscriptionError.normalize(_:)`. Ending iteration, or cancelling
    /// the consumer, cancels the work.
    private static func makeStream<Element: Sendable>(
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

    /// Opens the file for reading. When AVAudioFile rejects the file, the asset decides the error:
    /// a media file without audio throws `.noAudioTrack`, and anything else throws `.cannotOpenFile`.
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

    /// The transcriber for downloads and analysis. It reports final results only, each with its audio time range.
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// The locale a language choice asks for. Automatic uses the system language, because this engine cannot
    /// detect the spoken language.
    private static func requestedLocale(for language: LanguageChoice) -> Locale {
        switch language {
        case .automatic:
            return Locale.current
        case .specific(let locale):
            return locale
        }
    }

    private static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// The time in seconds, or nil when the time is not finite.
    private static func seconds(_ time: CMTime) -> TimeInterval? {
        time.seconds.isFinite ? time.seconds : nil
    }

    /// Progress while the job runs. It stays below 1, which is reported only when the job finishes.
    private static func clampedProgress(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 0.99)
    }
}
