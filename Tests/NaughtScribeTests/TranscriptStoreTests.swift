import Foundation
import Testing
import TranscriptionCore
@testable import NaughtScribe

@MainActor
struct TranscriptStoreTests {
    @Test func transcriptThatWasInProgressWhenTheAppQuitIsMarkedFailed() async throws {
        try await withTemporaryDirectory { directory in
            let firstLaunch = TranscriptStore(directory: directory)
            let transcript = Transcript(sourceFileName: "talk.m4a", languageIdentifier: "en-US")
            firstLaunch.add(transcript)  // Still in progress when the app quits.

            let relaunch = TranscriptStore(directory: directory)
            let loaded = try #require(relaunch.transcripts.first)
            #expect(loaded.id == transcript.id)
            #expect(loaded.status == .failed)
            #expect(loaded.errorMessage == "Interrupted: the app quit before transcription finished.")

            // The failure is saved too, so the launch after that loads the same state.
            #expect(TranscriptStore(directory: directory).transcripts.first?.status == .failed)
        }
    }

    @Test func transcriptFilesWrittenBeforeEnginesExistedStillLoad() async throws {
        try await withTemporaryDirectory { directory in
            let id = UUID()
            // A file from before engines and segments were stored: no engineID, modelID or segments keys.
            let json = """
            {
              "id": "\(id.uuidString)",
              "createdAt": "2025-03-01T10:00:00Z",
              "sourceFileName": "old.m4a",
              "languageIdentifier": "en-US",
              "status": "done",
              "progress": 1,
              "statusMessage": "Done",
              "text": "Text from before engines."
            }
            """
            try Data(json.utf8).write(to: directory.appending(path: "\(id.uuidString).json"))

            let loaded = try #require(TranscriptStore(directory: directory).transcripts.first)
            #expect(loaded.id == id)
            #expect(loaded.createdAt == Date(timeIntervalSince1970: 1_740_823_200))
            #expect(loaded.status == .done)
            #expect(loaded.text == "Text from before engines.")
            #expect(loaded.engineID == nil)
            #expect(loaded.modelID == nil)
            #expect(loaded.segments == nil)
        }
    }

    @Test func completedTranscriptIsLoadedAfterARelaunch() async throws {
        try await withTemporaryDirectory { directory in
            // Whole-second dates: the JSON stores dates to the second.
            var transcript = Transcript(
                createdAt: Date(timeIntervalSince1970: 1_740_823_200),
                sourceFileName: "hello.wav",
                languageIdentifier: "en-US"
            )
            transcript.status = .done
            transcript.progress = 1
            transcript.statusMessage = "Done"
            transcript.text = "Hello."
            transcript.engineID = "fake.engine"
            transcript.modelID = "fake-model"
            transcript.segments = [TranscriptSegment(text: "Hello.", start: 0, end: 0.9)]

            TranscriptStore(directory: directory).add(transcript)
            #expect(TranscriptStore(directory: directory).transcripts == [transcript])
        }
    }

    @Test func deleteRemovesTheTranscriptAndItsFile() async throws {
        try await withTemporaryDirectory { directory in
            let store = TranscriptStore(directory: directory)
            let transcript = Transcript(sourceFileName: "gone.m4a", languageIdentifier: "en-US")
            store.add(transcript)
            let file = directory.appending(path: "\(transcript.id.uuidString).json")
            #expect(FileManager.default.fileExists(atPath: file.path))

            store.delete(transcript.id)
            #expect(store.transcripts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path))

            // An update that arrives after the delete must not write the file back.
            store.update(transcript.id) { $0.progress = 0.5 }
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }
}
