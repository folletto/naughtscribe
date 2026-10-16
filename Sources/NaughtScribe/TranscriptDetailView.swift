import AppKit
import SwiftUI

/// The detail pane for one transcript: a progress card while it runs, the error if it failed, or the text when done.
struct TranscriptDetailView: View {
    let transcript: Transcript

    var body: some View {
        Group {
            switch transcript.status {
            case .inProgress:
                progressCard
            case .failed:
                failureCard
            case .done:
                textView
            }
        }
        .navigationTitle(transcript.sourceFileName)
        .navigationSubtitle(Text(transcript.createdAt.formatted(date: .abbreviated, time: .shortened)))
        .toolbar {
            if transcript.status == .done {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy Text", systemImage: "doc.on.doc", action: copyText)
                }
            }
        }
    }

    private var progressCard: some View {
        card {
            Text("Transcription in progress")
                .font(.title3.weight(.semibold))
            Text(transcript.statusMessage)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ProgressView(value: transcript.progress)
                Text(transcript.progress, format: .percent)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(transcript.sourceFileName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var failureCard: some View {
        card {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Transcription failed")
                .font(.title3.weight(.semibold))
            Text(transcript.errorMessage ?? "The transcription did not finish.")
                .textSelection(.enabled)
            Text(transcript.sourceFileName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var textView: some View {
        ScrollView {
            Text(transcript.text.isEmpty ? "No speech was detected in this file." : transcript.text)
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    /// A centered, padded panel for the in-progress and failed states.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            content()
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.text, forType: .string)
    }
}
