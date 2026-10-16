import Foundation
import Testing
import TranscriptionCore
@testable import NaughtScribe

/// The transcription queue of `AppModel`, run against fake engines and a temporary transcript store.
/// The suite runs one test at a time, because the model reads its settings from `UserDefaults.standard`.
@Suite(.serialized)
@MainActor
struct AppModelTests {
    init() {
        clearSettings()
    }

    @Test func importedFilesAreQueuedThenTranscribed() async throws {
        let engine = FakeEngine(scripts: [
            FakeEngine.Script(events: [
                .phase(.transcribing),
                .progress(0.5),
                .segment(sampleSegments[0]),
                .segment(sampleSegments[1]),
                .finished(sampleResult),
            ]),
        ])
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])

            model.importFiles([audioURL("first.m4a"), audioURL("second.wav")])
            // The queue runs on the main actor, which this test holds until it waits. Both are still queued here.
            #expect(model.store.transcripts.count == 2)
            #expect(model.store.transcripts.allSatisfy {
                $0.status == .inProgress && $0.statusMessage == "Waiting in queue"
            })

            #expect(await waitUntil { model.store.transcripts.allSatisfy { $0.status == .done } })
            let first = try #require(model.store.transcripts.first { $0.sourceFileName == "first.m4a" })
            #expect(first.text == "Hello there. General Kenobi.")
            #expect(first.segments == sampleSegments)
            #expect(first.engineID == "fake.engine")
            #expect(first.modelID == "fake-model")
            #expect(first.progress == 1)
            #expect(first.statusMessage == "Done")
        }
    }

    @Test func filesAreTranscribedOneAtATimeInTheOrderGiven() async throws {
        let engine = FakeEngine(scripts: [slowJob, FakeEngine.Script(events: [.finished(sampleResult)])])
        let urls = [audioURL("one.m4a"), audioURL("two.mp3")]
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])
            model.importFiles(urls)

            // While the first job transcribes, the second one waits for it.
            #expect(await waitUntil {
                model.store.transcripts.first { $0.sourceFileName == "one.m4a" }?.statusMessage == "Transcribing"
            })
            #expect(model.store.transcripts.first { $0.sourceFileName == "two.mp3" }?.statusMessage == "Waiting in queue")

            #expect(await waitUntil { model.store.transcripts.allSatisfy { $0.status == .done } })
            #expect(engine.requests.map(\.fileURL) == urls)
        }
    }

    @Test func everyPhaseHasAStatusLine() {
        #expect(AppModel.statusMessage(for: .preparingAudio) == "Preparing audio")
        #expect(AppModel.statusMessage(for: .downloadingModel) == "Downloading language model")
        #expect(AppModel.statusMessage(for: .loadingModel) == "Loading model")
        #expect(AppModel.statusMessage(for: .transcribing) == "Transcribing")
    }

    @Test func phaseEventsAppearInTheStatusWhileTheJobRuns() async throws {
        // The engine pauses before each event, so the job is still running when the status is checked.
        let engine = FakeEngine(scripts: [
            FakeEngine.Script(events: [.phase(.downloadingModel), .finished(sampleResult)], delay: .seconds(1)),
        ])
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])
            model.importFiles([audioURL("download.m4a")])
            let id = try #require(model.store.transcripts.first?.id)

            #expect(await waitUntil {
                model.store.transcripts.first { $0.id == id }?.statusMessage == "Downloading language model"
            })
            model.delete(id)
        }
    }

    @Test func engineErrorFailsTheTranscriptWithItsDescription() async throws {
        let failure = TranscriptionError.unsupportedLanguage("Klingon")
        let engine = FakeEngine(scripts: [FakeEngine.Script(error: failure)])
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])
            model.importFiles([audioURL("klingon.m4a")])

            #expect(await waitUntil { model.store.transcripts.allSatisfy { $0.status != .inProgress } })
            let transcript = try #require(model.store.transcripts.first)
            #expect(transcript.status == .failed)
            #expect(transcript.errorMessage == failure.errorDescription)
        }
    }

    @Test func streamThatEndsWithoutAResultFailsTheTranscript() async throws {
        let engine = FakeEngine(scripts: [
            FakeEngine.Script(events: [.phase(.transcribing), .progress(0.4)]),
        ])
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])
            model.importFiles([audioURL("cut-short.m4a")])

            #expect(await waitUntil { model.store.transcripts.allSatisfy { $0.status != .inProgress } })
            let transcript = try #require(model.store.transcripts.first)
            #expect(transcript.status == .failed)
            #expect(transcript.errorMessage == "Transcription ended without a result.")
        }
    }

    @Test func jobFailsWhenNoEngineCanRun() async throws {
        let engine = FakeEngine(availability: .unavailable(reason: "Needs Apple silicon."))
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])
            model.importFiles([audioURL("song.m4a")])

            #expect(await waitUntil { model.store.transcripts.allSatisfy { $0.status != .inProgress } })
            let transcript = try #require(model.store.transcripts.first)
            #expect(transcript.status == .failed)
            #expect(transcript.errorMessage == "No transcription engine is available on this Mac.")
            #expect(engine.requests.isEmpty)
        }
    }

    @Test func deletingARunningJobCancelsItAndTheQueueGoesOn() async throws {
        let engine = FakeEngine(scripts: [slowJob, FakeEngine.Script(events: [.finished(sampleResult)])])
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])
            model.importFiles([audioURL("running.m4a"), audioURL("next.m4a")])
            let runningID = try #require(model.store.transcripts.first { $0.sourceFileName == "running.m4a" }?.id)
            #expect(await waitUntil {
                model.store.transcripts.first { $0.id == runningID }?.statusMessage == "Transcribing"
            })
            let file = directory.appending(path: "\(runningID.uuidString).json")
            #expect(FileManager.default.fileExists(atPath: file.path))

            model.delete(runningID)
            #expect(model.store.transcripts.allSatisfy { $0.id != runningID })
            #expect(!FileManager.default.fileExists(atPath: file.path))

            #expect(await waitUntil { engine.cancelledRequests == 1 })
            #expect(await waitUntil {
                model.store.transcripts.first { $0.sourceFileName == "next.m4a" }?.status == .done
            })
            #expect(model.store.transcripts.map(\.sourceFileName) == ["next.m4a"])
        }
    }

    @Test func deletingAQueuedJobMeansItIsNeverTranscribed() async throws {
        let engine = FakeEngine(scripts: [FakeEngine.Script(events: [.finished(sampleResult)])])
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])
            model.importFiles([audioURL("first.m4a"), audioURL("skipped.m4a"), audioURL("last.m4a")])
            let skippedID = try #require(model.store.transcripts.first { $0.sourceFileName == "skipped.m4a" }?.id)
            model.delete(skippedID)

            #expect(await waitUntil { model.store.transcripts.allSatisfy { $0.status == .done } })
            #expect(engine.requests.map(\.fileURL.lastPathComponent) == ["first.m4a", "last.m4a"])
        }
    }

    @Test func importingOnlyNonAudioFilesAddsNothing() async throws {
        let engine = FakeEngine()
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [engine])
            let accepted = model.importFiles([audioURL("notes.pdf"), audioURL("photo.jpg")])
            #expect(accepted == false)
            #expect(model.store.transcripts.isEmpty)
            #expect(engine.requests.isEmpty)
        }
    }

    @Test func settingsChooseTheEngineAndLanguageForNewJobs() async throws {
        defer { clearSettings() }
        UserDefaults.standard.set("fake.chosen", forKey: AppSettings.transcriptionEngineKey)
        UserDefaults.standard.set("de-DE", forKey: AppSettings.transcriptionLanguageKey)
        let fallback = FakeEngine(id: "fake.fallback", priority: 0)
        let chosen = FakeEngine(
            id: "fake.chosen",
            priority: 5,
            scripts: [FakeEngine.Script(events: [.finished(sampleResult)])]
        )
        try await withTemporaryDirectory { directory in
            let model = makeModel(directory: directory, engines: [fallback, chosen])
            model.importFiles([audioURL("german.m4a")])

            #expect(await waitUntil { model.store.transcripts.allSatisfy { $0.status == .done } })
            let transcript = try #require(model.store.transcripts.first)
            #expect(transcript.engineID == "fake.chosen")
            #expect(transcript.languageIdentifier == "de-DE")
            #expect(fallback.requests.isEmpty)
            #expect(chosen.requests.first?.selection.language == LanguageChoice.specific(Locale(identifier: "de-DE")))
        }
    }
}

// MARK: - Helpers

/// The segments every fake job returns.
private let sampleSegments = [
    TranscriptSegment(text: " Hello there. ", start: 0, end: 1.5),
    TranscriptSegment(text: "General Kenobi.", start: 1.5, end: 3),
]

/// The result every fake job finishes with.
private let sampleResult = TranscriptionResult(
    segments: sampleSegments,
    detectedLanguage: nil,
    engineID: "fake.engine",
    modelID: "fake-model"
)

/// A job that pauses a second before each event. It is still transcribing for a second, so a test can act on it.
private let slowJob = FakeEngine.Script(
    events: [.phase(.transcribing), .finished(sampleResult)],
    delay: .seconds(1)
)

/// A URL for an audio file that does not exist. The fake engines never read it.
private func audioURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/nonexistent/\(name)")
}

/// Removes the settings that `AppModel` reads, so a value stored on this Mac does not change the tests.
private func clearSettings() {
    UserDefaults.standard.removeObject(forKey: AppSettings.transcriptionEngineKey)
    UserDefaults.standard.removeObject(forKey: AppSettings.transcriptionLanguageKey)
}

/// A model whose jobs run on `engines`, with its transcripts kept in `directory`.
@MainActor
private func makeModel(directory: URL, engines: [any TranscriptionEngine]) -> AppModel {
    AppModel(store: TranscriptStore(directory: directory), registry: EngineRegistry(engines: engines))
}
