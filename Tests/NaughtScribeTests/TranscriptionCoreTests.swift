import AVFoundation
import Foundation
import Testing
import TranscriptionCore

struct TranscriptionResultTests {
    @Test func textJoinsTrimmedNonEmptySegmentsWithSingleSpaces() {
        let result = TranscriptionResult(
            segments: [
                TranscriptSegment(text: "  Hello ", start: 0, end: 1),
                TranscriptSegment(text: "", start: 1, end: 1.2),
                TranscriptSegment(text: " \n\t ", start: 1.2, end: 1.4),
                TranscriptSegment(text: "world\n", start: 1.4, end: 2),
                TranscriptSegment(text: "again", start: 2, end: 3),
            ],
            detectedLanguage: nil,
            engineID: "fake.engine",
            modelID: nil
        )
        #expect(result.text == "Hello world again")
    }

    @Test func textIsEmptyWithoutSegments() {
        let result = TranscriptionResult(segments: [], detectedLanguage: nil, engineID: "fake.engine", modelID: nil)
        #expect(result.text.isEmpty)
    }
}

@MainActor
struct AudioDecoderTests {
    @Test func stereo44kFileDecodesToOneSecondOfMono16kSamples() async throws {
        try await withTemporaryDirectory { directory in
            let url = try writeSineWAV(in: directory, seconds: 1, sampleRate: 44_100)
            let samples = try await AudioDecoder.decodeMono16k(fileURL: url)
            // One second at 16 kHz is 16,000 samples. Allow 1 percent for the converter's edges.
            #expect(abs(samples.count - 16_000) <= 160)
            // The tone survives the conversion, so the samples are not silence.
            #expect(samples.contains { abs($0) > 0.1 })
        }
    }

    @Test func aTextFileIsNotReadableAsAudio() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: "notes.txt")
            try Data("Not audio.".utf8).write(to: url)
            await #expect(throws: TranscriptionError.cannotOpenFile("notes.txt")) {
                _ = try await AudioDecoder.decodeMono16k(fileURL: url)
            }
        }
    }

    /// Writes a 440 Hz tone as a 16-bit stereo WAV file and returns its URL.
    private func writeSineWAV(in directory: URL, seconds: Double, sampleRate: Double) throws -> URL {
        let url = directory.appending(path: "tone.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        // The file is written when `file` is released, which happens when this function returns.
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameCount) {
                channels[channel][frame] = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }
}
