import Foundation
import Observation

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

    private let service = TranscriptionService()
    private var queue: [Job] = []
    private var isWorking = false
    private var activeJob: (id: UUID, task: Task<Void, Never>)?

    init() {
        store = TranscriptStore()
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

        var lastSave: ContinuousClock.Instant?
        do {
            for try await update in service.transcribe(fileURL: job.fileURL, locale: job.locale) {
                if let text = update.text {
                    store.update(job.transcriptID) { transcript in
                        transcript.status = .done
                        transcript.progress = 1
                        transcript.statusMessage = "Done"
                        transcript.text = text
                    }
                } else {
                    // Each save rewrites the transcript file, so progress is saved at most twice a second.
                    let now = ContinuousClock.now
                    if let lastSave, now - lastSave < .milliseconds(500) {
                        continue
                    }
                    lastSave = now
                    store.update(job.transcriptID) { transcript in
                        transcript.progress = update.progress
                        transcript.statusMessage = update.statusMessage
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
}
