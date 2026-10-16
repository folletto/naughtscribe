import Foundation
import Observation
import os

/// The transcript list, persisted as one `<uuid>.json` file per transcript in Application Support.
/// All methods run on the main actor. Create one store per process for a given directory.
@MainActor
@Observable
final class TranscriptStore {
    private static let logger = Logger(subsystem: "com.naughtscribe.app", category: "TranscriptStore")
    private static let interruptedMessage = "Interrupted: the app quit before transcription finished."

    /// Newest first.
    private(set) var transcripts: [Transcript] = []

    private let directory: URL

    /// - Parameter directory: Where transcript files live. Defaults to
    ///   `Application Support/NaughtScribe/Transcripts`. Pass a temporary directory in tests and previews.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        createDirectoryIfNeeded()
        loadFromDisk()
    }

    /// Inserts the transcript (replacing any with the same id) and saves it.
    func add(_ transcript: Transcript) {
        transcripts.removeAll { $0.id == transcript.id }
        transcripts.append(transcript)
        sortNewestFirst()
        save(transcript)
    }

    /// Mutates one transcript in place and saves it. Does nothing if the id is unknown, so a late
    /// progress update for a deleted transcript does not recreate its file.
    func update(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let index = transcripts.firstIndex(where: { $0.id == id }) else { return }
        change(&transcripts[index])
        save(transcripts[index])
    }

    /// Removes the transcript from the list and deletes its file.
    func delete(_ id: UUID) {
        transcripts.removeAll { $0.id == id }
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error("Could not delete transcript \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Case- and diacritic-insensitive match against each transcript's text and source file name.
    /// A query that is empty after trimming returns every transcript.
    func filtered(by query: String) -> [Transcript] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return transcripts }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return transcripts.filter { transcript in
            transcript.text.range(of: needle, options: options) != nil
                || transcript.sourceFileName.range(of: needle, options: options) != nil
        }
    }

    // MARK: - Loading and saving

    private static func defaultDirectory() -> URL {
        let applicationSupport: URL
        do {
            applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            // Should not happen. Keep working from a temporary location instead of crashing.
            Self.logger.error("Application Support unavailable, using temporary directory: \(error.localizedDescription, privacy: .public)")
            applicationSupport = FileManager.default.temporaryDirectory
        }
        return applicationSupport
            .appendingPathComponent("NaughtScribe", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    private func createDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Could not create \(self.directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFromDisk() {
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            Self.logger.error("Could not list transcripts: \(error.localizedDescription, privacy: .public)")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [Transcript] = []
        for url in fileURLs where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                loaded.append(try decoder.decode(Transcript.self, from: data))
            } catch {
                Self.logger.error("Skipping unreadable transcript \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Interruption rule: work still in progress at launch was cut off when the app quit.
        for index in loaded.indices where loaded[index].status == .inProgress {
            loaded[index].status = .failed
            loaded[index].errorMessage = Self.interruptedMessage
            save(loaded[index])
        }

        transcripts = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save(_ transcript: Transcript) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(transcript)
            try data.write(to: fileURL(for: transcript.id), options: .atomic)
        } catch {
            Self.logger.error("Could not save transcript \(transcript.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func sortNewestFirst() {
        transcripts.sort { $0.createdAt > $1.createdAt }
    }
}
