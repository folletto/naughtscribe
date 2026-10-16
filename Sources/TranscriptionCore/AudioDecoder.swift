import AVFoundation
import Foundation

/// Converts audio files to the format whisper-style engines need.
public enum AudioDecoder {
    /// Sample rate of the decoded samples, in hertz.
    public static let sampleRate: Double = 16_000

    /// Source frames read per conversion step. Bounds memory use for long files.
    private static let inputChunkFrames: AVAudioFrameCount = 65_536
    /// Converted frames produced per conversion call.
    private static let outputChunkFrames: AVAudioFrameCount = 16_384

    /// Reads the whole file and returns 16 kHz mono Float32 samples. The file is converted in chunks.
    /// Cancelling the calling task throws `CancellationError`, which `TranscriptionError.normalize(_:)` maps
    /// to `.cancelled`. Throws `.cannotOpenFile` or `.noAudioTrack` when the file cannot be read as audio.
    public static func decodeMono16k(fileURL: URL) async throws -> [Float] {
        let file = try await openAudioFile(at: fileURL)
        let inputFormat = file.processingFormat
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputChunkFrames)
        else {
            throw TranscriptionError.engineFailed("The audio could not be converted to 16 kHz mono.")
        }
        // With the default algorithm, chunked input yields only a small part of the output. MinimumPhase
        // converts all of it, with the quality needed for speech.
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
        let feeder = ChunkFeeder(file: file, chunkFrames: inputChunkFrames)

        var samples: [Float] = []
        // Reserve once up front, so that appending does not reallocate repeatedly for long files.
        let estimate = Double(file.length) * sampleRate / inputFormat.sampleRate
        if estimate.isFinite, estimate >= 1, estimate < Double(Int32.max) {
            samples.reserveCapacity(Int(estimate))
        }

        while true {
            try Task.checkCancellation()
            do {
                try feeder.loadNextChunk()
            } catch let error as TranscriptionError {
                throw error
            } catch {
                throw TranscriptionError.cannotOpenFile(fileURL.lastPathComponent)
            }
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                feeder.supply(status: inputStatus)
            }
            if let channel = outputBuffer.floatChannelData?[0], outputBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
            }

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                return samples
            case .error:
                throw TranscriptionError.engineFailed(
                    conversionError?.localizedDescription ?? "The audio could not be converted."
                )
            @unknown default:
                throw TranscriptionError.engineFailed("The audio could not be converted.")
            }
        }
    }

    /// Duration in seconds, or nil if the file cannot be opened as audio.
    public static func duration(of fileURL: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    /// Opens a file for reading. When AVAudioFile rejects the file, the asset's audio tracks decide the error:
    /// a media file without audio throws `.noAudioTrack`, and anything else throws `.cannotOpenFile`.
    public static func openAudioFile(at url: URL) async throws -> AVAudioFile {
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
}

/// Feeds one audio file to an `AVAudioConverter` a chunk at a time. `loadNextChunk()` runs between
/// conversion calls, and `supply(status:)` runs inside `convert`, which calls it synchronously. Both run on
/// the calling task, so the mutable state here is never accessed concurrently.
private final class ChunkFeeder: @unchecked Sendable {
    private let file: AVAudioFile
    private let chunkFrames: AVAudioFrameCount
    /// A chunk read from the file that has not yet been handed to the converter.
    private var pending: AVAudioPCMBuffer?
    private var reachedEnd = false

    init(file: AVAudioFile, chunkFrames: AVAudioFrameCount) {
        self.file = file
        self.chunkFrames = chunkFrames
    }

    /// Reads the next chunk into `pending`, or marks the end of the file. Does nothing while a chunk is pending.
    func loadNextChunk() throws {
        guard pending == nil, !reachedEnd else { return }
        // AVAudioFile throws when read past the end, so the position is checked before every read.
        let remaining = file.length - file.framePosition
        guard remaining > 0 else {
            reachedEnd = true
            return
        }
        let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw TranscriptionError.engineFailed("The audio buffer could not be allocated.")
        }
        try file.read(into: buffer, frameCount: frames)
        if buffer.frameLength == 0 {
            reachedEnd = true
        } else {
            pending = buffer
        }
    }

    /// The converter's input callback. It hands over the pending chunk once. When nothing is pending, it reports
    /// the end of the file, or that no data is available yet.
    func supply(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let buffer = pending {
            pending = nil
            status.pointee = .haveData
            return buffer
        }
        status.pointee = reachedEnd ? .endOfStream : .noDataNow
        return nil
    }
}
