import AVFoundation
import Foundation
import Speech
import TranscriptionCore

/// Transcribes files on-device with the older `SFSpeechRecognizer` API. Works on Intel Macs, where
/// `SpeechTranscriberEngine` cannot run, but is less accurate. The engine cannot download language data, so the
/// user installs each language through Dictation in System Settings first.
public struct SFSpeechRecognizerEngine: TranscriptionEngine {
    public let descriptor = EngineDescriptor(
        id: "apple.sfspeech",
        name: "Apple Speech (Legacy)",
        summary: "Apple’s older on-device recognizer. Works on Intel Macs; less accurate.",
        priority: 10
    )

    /// The only model this engine offers. The system holds the language data, one set per language.
    private static let modelID = "default"
    private static let noOnDeviceReason =
        "On-device speech recognition is not available on this Mac. "
        + "Turn on Dictation in System Settings > Keyboard to download it."
    private static let authorizationReason =
        "NaughtScribe is not allowed to use speech recognition. "
        + "Allow it in System Settings > Privacy & Security > Speech Recognition."
    /// The domain of the Speech framework's errors. The framework header documents the name, but Swift does not
    /// expose a constant for it.
    private static let assistantErrorDomain = "kAFAssistantErrorDomain"
    /// The Speech framework's error for audio that contains no speech.
    private static let noSpeechErrorCode = 1110

    private typealias EventContinuation = AsyncThrowingStream<TranscriptionEvent, Error>.Continuation

    public init() {}

    public func availability() async -> EngineAvailability {
        let hasOnDeviceLocale = SFSpeechRecognizer.supportedLocales().contains { Self.supportsOnDevice($0) }
        return hasOnDeviceLocale ? .available : .unavailable(reason: Self.noOnDeviceReason)
    }

    public func languageSupport() async -> LanguageSupport {
        let locales = SFSpeechRecognizer.supportedLocales().filter { Self.supportsOnDevice($0) }
        return LanguageSupport(locales: locales.sorted { $0.identifier < $1.identifier }, supportsAutoDetect: false)
    }

    /// The one model. `ModelSelection.modelID` is therefore not used.
    public func models() async -> [ModelDescriptor] {
        [ModelDescriptor(id: Self.modelID, name: "Default", downloadSizeBytes: nil, locales: nil)]
    }

    /// Ready when `prepare` and `run` would find a recognizer that runs on-device for the language.
    public func modelState(for selection: ModelSelection) async -> ModelState {
        let requested = Self.requestedLocale(for: selection.language)
        guard (try? Self.onDeviceRecognizer(for: requested)) != nil else { return .unsupported }
        return .ready
    }

    /// Nothing is downloaded, because this engine cannot download language data. Yields 0 and 1 when the language
    /// can run on-device. Otherwise it fails with `.unsupportedLanguage` when no supported locale has the language,
    /// or with a Dictation hint when the matched locale cannot run on-device.
    public func prepare(_ selection: ModelSelection) -> AsyncThrowingStream<Double, Error> {
        TranscriptionStream.make { continuation in
            _ = try Self.onDeviceRecognizer(for: Self.requestedLocale(for: selection.language))
            continuation.yield(0)
            continuation.yield(1)
        }
    }

    public func transcribe(_ request: TranscriptionRequest) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        TranscriptionStream.make { continuation in
            try await self.run(request, continuation: continuation)
        }
    }

    // MARK: - Jobs

    /// Runs one job and yields its events. The last event is `.finished`.
    private func run(_ request: TranscriptionRequest, continuation: EventContinuation) async throws {
        continuation.yield(.phase(.preparingAudio))
        try await Self.ensureAuthorized()
        let requested = Self.requestedLocale(for: request.selection.language)
        let (locale, recognizer) = try Self.onDeviceRecognizer(for: requested)
        guard recognizer.isAvailable else {
            throw TranscriptionError.engineUnavailable(Self.notAvailableNowReason(for: locale))
        }

        let audioFile = try await AudioDecoder.openAudioFile(at: request.fileURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalSeconds = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0

        continuation.yield(.phase(.transcribing))
        let segments = try await Self.recognize(
            fileURL: request.fileURL,
            recognizer: recognizer,
            totalSeconds: totalSeconds,
            events: continuation
        )
        continuation.yield(.finished(TranscriptionResult(
            segments: segments.sorted { ($0.start ?? 0) < ($1.start ?? 0) },
            detectedLanguage: locale,
            engineID: descriptor.id,
            modelID: Self.modelID
        )))
    }

    // MARK: - Model and Authorization

    /// Whether the locale has a recognizer that can run on-device.
    private static func supportsOnDevice(_ locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

    /// The recognizer for the locale that matches `requested`, and that locale. The recognizer must run on-device.
    /// Throws `.unsupportedLanguage` when no supported locale has the language, and `.engineUnavailable` with a
    /// Dictation hint when the matched locale cannot run on-device.
    private static func onDeviceRecognizer(
        for requested: Locale
    ) throws -> (locale: Locale, recognizer: SFSpeechRecognizer) {
        guard let locale = matchedLocale(for: requested), let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.unsupportedLanguage(displayName(for: requested))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.engineUnavailable(dictationHint(for: locale))
        }
        return (locale, recognizer)
    }

    /// The supported locale that transcribes `requested`, or nil when no supported locale has its language. A locale
    /// that can run on-device is preferred. Only when none has the language is a locale that cannot run on-device
    /// matched, so that the Dictation hint names the language the user has to install.
    private static func matchedLocale(for requested: Locale) -> Locale? {
        let supported = Array(SFSpeechRecognizer.supportedLocales())
        let onDevice = supported.filter { supportsOnDevice($0) }
        return bestMatch(for: requested, among: onDevice) ?? bestMatch(for: requested, among: supported)
    }

    /// Asks for speech recognition permission when it has not been decided yet, then throws unless it is granted.
    private static func ensureAuthorized() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await askForAuthorization()
        }
        if let error = authorizationError(for: status) {
            throw error
        }
    }

    /// Shows the system prompt for speech recognition and returns the answer.
    private static func askForAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// The error that stops a job when speech recognition is not authorized, or nil when it is authorized.
    static func authorizationError(for status: SFSpeechRecognizerAuthorizationStatus) -> TranscriptionError? {
        status == .authorized ? nil : TranscriptionError.engineUnavailable(authorizationReason)
    }

    // MARK: - Recognition

    /// Recognizes the file with one request. Returns the segments of the utterances that finished, in the order they
    /// finished. Cancelling the calling task cancels the recognition.
    private static func recognize(
        fileURL: URL,
        recognizer: SFSpeechRecognizer,
        totalSeconds: Double,
        events: EventContinuation
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let job = RecognitionJob(totalSeconds: totalSeconds, events: events)
        // The job holds the task until it finishes. The recognizer is a parameter, so it lives for the whole call.
        job.keep(recognizer.recognitionTask(with: request, delegate: job))
        let segments = try await withTaskCancellationHandler {
            try await job.waitForResult()
        } onCancel: {
            job.cancel()
        }
        try Task.checkCancellation()
        return segments
    }

    /// Receives the callbacks of one recognition task. Each finished utterance becomes a segment and an event, and the
    /// end of the task ends the wait in `recognize`. The state is guarded by `lock`. Events are yielded under the lock
    /// and only before the job finishes, so no event follows `.finished`.
    private final class RecognitionJob: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
        private typealias Waiter = CheckedContinuation<[TranscriptSegment], Error>
        private typealias Outcome = Result<[TranscriptSegment], Error>

        private let lock = NSLock()
        private let totalSeconds: Double
        private let events: EventContinuation
        /// The task, held until the job finishes. `cancel()` cancels it.
        private var runningTask: SFSpeechRecognitionTask?
        private var segments: [TranscriptSegment] = []
        /// The furthest progress reported so far. Progress never decreases.
        private var progress: Double = 0
        /// Set once the job has finished. Later calls have no effect.
        private var outcome: Outcome?
        /// The call that waits for the outcome, until the outcome is known.
        private var waiter: Waiter?

        init(totalSeconds: Double, events: EventContinuation) {
            self.totalSeconds = totalSeconds
            self.events = events
            super.init()
        }

        /// Holds `task` until the job finishes, so that `cancel()` can cancel it.
        func keep(_ task: SFSpeechRecognitionTask) {
            lock.withLock {
                guard outcome == nil else { return }
                runningTask = task
            }
        }

        /// Suspends until the job finishes. Returns the segments, or throws the failure.
        func waitForResult() async throws -> [TranscriptSegment] {
            try await withCheckedThrowingContinuation { (waiting: Waiter) in
                let known: Outcome? = lock.withLock { () -> Outcome? in
                    if let outcome {
                        return outcome
                    }
                    waiter = waiting
                    return nil
                }
                if let known {
                    waiting.resume(with: known)
                }
            }
        }

        /// Cancels the task and ends the job with `CancellationError`. Safe to call from any thread.
        func cancel() {
            let current = lock.withLock { runningTask }
            // Outside the lock, because cancelling the task may call the delegate.
            current?.cancel()
            finish(failure: CancellationError())
        }

        // MARK: SFSpeechRecognitionTaskDelegate

        func speechRecognitionTask(
            _ task: SFSpeechRecognitionTask,
            didHypothesizeTranscription transcription: SFTranscription
        ) {
            let end = transcription.segments.last.map { $0.timestamp + $0.duration }
            lock.withLock {
                guard outcome == nil else { return }
                reportProgress(endingAt: end)
            }
        }

        func speechRecognitionTask(
            _ task: SFSpeechRecognitionTask,
            didFinishRecognition recognitionResult: SFSpeechRecognitionResult
        ) {
            guard let segment = SFSpeechRecognizerEngine.segment(from: recognitionResult.bestTranscription) else {
                return
            }
            lock.withLock {
                guard outcome == nil else { return }
                segments.append(segment)
                events.yield(.segment(segment))
                reportProgress(endingAt: segment.end)
            }
        }

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
            if successfully {
                finish(failure: nil)
            } else if let error = task.error, SFSpeechRecognizerEngine.isNoSpeechError(error) {
                finish(failure: nil)
            } else {
                let detail = task.error?.localizedDescription ?? "The recognition did not finish."
                finish(failure: TranscriptionError.engineFailed(detail))
            }
        }

        func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
            finish(failure: CancellationError())
        }

        // MARK: Job state

        /// Yields progress for speech ending at `end`, if that is further than before. Call with `lock` held.
        private func reportProgress(endingAt end: TimeInterval?) {
            guard let end, totalSeconds > 0 else { return }
            let fraction = SFSpeechRecognizerEngine.clampedProgress(end / totalSeconds)
            guard fraction > progress else { return }
            progress = fraction
            events.yield(.progress(fraction))
        }

        /// Ends the job with the segments, or with `failure` when it is not nil. Only the first call has an effect.
        private func finish(failure: Error?) {
            let completion = lock.withLock { () -> (waiter: Waiter, outcome: Outcome)? in
                guard outcome == nil else { return nil }
                let result: Outcome
                if let failure {
                    result = .failure(failure)
                } else {
                    result = .success(segments)
                }
                outcome = result
                runningTask = nil
                guard let waiting = waiter else { return nil }
                waiter = nil
                return (waiting, result)
            }
            // Resumed outside the lock. The outcome is already stored, so a later `waitForResult()` returns at once.
            if let completion {
                completion.waiter.resume(with: completion.outcome)
            }
        }
    }

    /// The segment for one finished utterance, or nil when its text is empty.
    static func segment(from transcription: SFTranscription) -> TranscriptSegment? {
        segment(
            text: transcription.formattedString,
            wordTimes: transcription.segments.map { (timestamp: $0.timestamp, duration: $0.duration) }
        )
    }

    /// A segment from its text and the timing of its words. The start is the first word's start, and the end is the
    /// last word's end. Both are nil when there are no words. Returns nil when the text is empty after trimming.
    static func segment(
        text: String,
        wordTimes: [(timestamp: TimeInterval, duration: TimeInterval)]
    ) -> TranscriptSegment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let start = wordTimes.first?.timestamp
        let end = wordTimes.last.map { $0.timestamp + $0.duration }
        return TranscriptSegment(
            text: trimmed,
            start: start.flatMap(finiteSeconds),
            end: end.flatMap(finiteSeconds)
        )
    }

    /// Whether the error means that the audio contains no speech.
    static func isNoSpeechError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == assistantErrorDomain && nsError.code == noSpeechErrorCode
    }

    /// Progress while a job runs. It stays below 1, which is reported only when the job finishes.
    static func clampedProgress(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 0.99)
    }

    // MARK: - Helpers

    /// The locale a language choice asks for. Automatic uses the system language, because this engine cannot
    /// detect the spoken language.
    static func requestedLocale(for language: LanguageChoice) -> Locale {
        switch language {
        case .automatic:
            return Locale.current
        case .specific(let locale):
            return locale
        }
    }

    /// The candidate that best matches `requested`, or nil when no candidate has its language. Script, variants and
    /// keywords are ignored, so `en_US@rg=itzzzz` matches `en_US`. The region is read from `language`, because
    /// `region` follows the `rg` keyword and would say Italy here. The order of preference is an identical identifier,
    /// then the same language in the same region, then the same language in any region. Within a group, the candidate
    /// whose identifier sorts first wins, so the result does not depend on the order of `candidates`.
    static func bestMatch(for requested: Locale, among candidates: [Locale]) -> Locale? {
        let ordered = candidates.sorted { $0.identifier < $1.identifier }
        if let identical = ordered.first(where: { $0.identifier == requested.identifier }) {
            return identical
        }
        guard let language = requested.language.languageCode else { return nil }
        let sameLanguage = ordered.filter { $0.language.languageCode == language }
        return sameLanguage.first { $0.language.region == requested.language.region } ?? sameLanguage.first
    }

    private static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// The sentence that asks for Dictation to be turned on for a language. Dictation is the only way its data arrives.
    private static func dictationHint(for locale: Locale) -> String {
        "Turn on Dictation for \(displayName(for: locale)) in System Settings > Keyboard "
            + "to install its on-device speech data, because this engine cannot download language data itself."
    }

    /// The sentence for a recognizer that can run on-device but is not available now (`isAvailable` is false).
    private static func notAvailableNowReason(for locale: Locale) -> String {
        "Speech recognition for \(displayName(for: locale)) is not available right now. "
            + "Try again later, or turn on Dictation in System Settings > Keyboard."
    }

    /// The time in seconds, or nil when the time is not finite.
    private static func finiteSeconds(_ value: TimeInterval) -> TimeInterval? {
        value.isFinite ? value : nil
    }
}
