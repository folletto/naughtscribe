import Foundation
import Observation
import TranscriptionCore

/// File extensions the transcription pipeline accepts. Other files are ignored when they are dropped or opened.
enum AudioFileTypes {
    static let extensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac", "mp4", "mov"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

/// App-wide state: the transcript store, the selected transcript, and the queue that transcribes imported files.
@MainActor
@Observable
final class AppModel {
    let store: TranscriptStore
    var selectedID: UUID?

    private struct Job {
        let transcriptID: UUID
        let fileURL: URL
        let locale: Locale
    }

    private let registry: EngineRegistry
    private var queue: [Job] = []
    private var isWorking = false
    private var activeJob: (id: UUID, task: Task<Void, Never>)?

    /// - Parameters:
    ///   - store: Where transcripts are kept. Tests pass a store in a temporary directory.
    ///   - registry: The engines a job can use. Tests pass fake engines.
    init(store: TranscriptStore = TranscriptStore(), registry: EngineRegistry = .shared) {
        self.store = store
        self.registry = registry
    }

    /// Adds a transcript for each audio file at once, then transcribes the files one at a time, in the order given.
    /// Returns false when none of the URLs is an audio file.
    @discardableResult
    func importFiles(_ urls: [URL]) -> Bool {
        let audioFiles = urls.filter(AudioFileTypes.isSupported)
        guard !audioFiles.isEmpty else { return false }

        let locale = AppSettings.resolvedLocale()
        for url in audioFiles {
            var transcript = Transcript(
                sourceFileName: url.lastPathComponent,
                languageIdentifier: locale.identifier(.bcp47)
            )
            transcript.statusMessage = "Waiting in queue"
            store.add(transcript)
            queue.append(Job(transcriptID: transcript.id, fileURL: url, locale: locale))
        }
        startWorkerIfNeeded()
        return true
    }

    /// Removes a transcript and its file. A transcription that is still running is cancelled.
    func delete(_ id: UUID) {
        queue.removeAll { $0.transcriptID == id }
        if activeJob?.id == id {
            activeJob?.task.cancel()
        }
        store.delete(id)
        if selectedID == id {
            selectedID = nil
        }
    }

    // MARK: - Queue

    /// Starts the worker that drains the queue, unless one is already running.
    private func startWorkerIfNeeded() {
        guard !isWorking else { return }
        isWorking = true
        Task { await self.drainQueue() }
    }

    /// Runs queued jobs in order until the queue is empty. Each job gets its own task, so that `delete(_:)`
    /// can cancel one job without stopping the queue.
    private func drainQueue() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            let task = Task { await self.transcribe(job) }
            activeJob = (job.transcriptID, task)
            await task.value
            activeJob = nil
        }
        isWorking = false
    }

    private func transcribe(_ job: Job) async {
        // The transcript may have been deleted after it was dequeued.
        guard store.transcripts.contains(where: { $0.id == job.transcriptID }) else { return }
        selectedID = job.transcriptID
        store.update(job.transcriptID) { $0.statusMessage = "Preparing audio" }

        // However the job ends, the transcript must not be left in progress.
        defer {
            if store.transcripts.first(where: { $0.id == job.transcriptID })?.status == .inProgress {
                store.update(job.transcriptID) { transcript in
                    transcript.status = .failed
                    transcript.errorMessage = "Transcription ended without a result."
                }
            }
        }

        // The engine is chosen per job, so a change in Settings applies to the next job.
        guard let engine = await registry.resolve(preferredID: AppSettings.preferredEngineID()) else {
            store.update(job.transcriptID) { transcript in
                transcript.status = .failed
                transcript.errorMessage = "No transcription engine is available on this Mac."
            }
            return
        }
        store.update(job.transcriptID) { $0.engineID = engine.descriptor.id }

        // Files chosen by the user in this sandboxed app are security-scoped; access must stay open while reading.
        let startedScopedAccess = job.fileURL.startAccessingSecurityScopedResource()
        defer {
            if startedScopedAccess { job.fileURL.stopAccessingSecurityScopedResource() }
        }

        let request = TranscriptionRequest(
            fileURL: job.fileURL,
            selection: ModelSelection(modelID: nil, language: .specific(job.locale))
        )
        var lastSave: ContinuousClock.Instant?
        do {
            for try await event in engine.transcribe(request) {
                switch event {
                case .phase(let phase):
                    // Steps change rarely, so each change is saved right away.
                    let message = Self.statusMessage(for: phase)
                    store.update(job.transcriptID) { $0.statusMessage = message }
                case .progress(let fraction):
                    // Each save rewrites the transcript file, so progress is saved at most twice a second.
                    let now = ContinuousClock.now
                    if let lastSave, now - lastSave < .milliseconds(500) {
                        continue
                    }
                    lastSave = now
                    store.update(job.transcriptID) { $0.progress = fraction }
                case .segment:
                    // Segments are delivered again in `.finished`, so they are not stored one by one.
                    break
                case .finished(let result):
                    store.update(job.transcriptID) { transcript in
                        transcript.status = .done
                        transcript.progress = 1
                        transcript.statusMessage = "Done"
                        transcript.text = result.text
                        transcript.segments = result.segments
                        transcript.modelID = result.modelID
                    }
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            store.update(job.transcriptID) { transcript in
                transcript.status = .failed
                transcript.errorMessage = message
            }
        }
    }

    /// The status line shown for each step of a job. All user-facing job text is defined here.
    static func statusMessage(for phase: TranscriptionPhase) -> String {
        switch phase {
        case .preparingAudio:
            return "Preparing audio"
        case .downloadingModel:
            return "Downloading language model"
        case .loadingModel:
            return "Loading model"
        case .transcribing:
            return "Transcribing"
        }
    }
}
