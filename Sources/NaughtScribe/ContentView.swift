import SwiftUI

/// The main window: the transcript list in the sidebar and the selected transcript in the detail pane.
/// The whole window accepts dropped audio files.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var isDropTargeted = false
    /// The transcript waiting for an answer in the delete confirmation.
    @State private var transcriptToDelete: Transcript?

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            let transcripts = model.store.filtered(by: searchText)
            List(selection: $model.selectedID) {
                ForEach(transcripts) { transcript in
                    TranscriptRow(transcript: transcript)
                        .tag(transcript.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                transcriptToDelete = transcript
                            }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if transcripts.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "Search transcripts")
            .confirmationDialog(
                "Delete this transcript?",
                isPresented: isConfirmingDelete,
                titleVisibility: .visible,
                presenting: transcriptToDelete
            ) { transcript in
                Button("Delete", role: .destructive) {
                    model.delete(transcript.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { transcript in
                Text("“\(transcript.sourceFileName)” and its text will be permanently deleted.")
            }
        } detail: {
            detail
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    @ViewBuilder
    private var detail: some View {
        if let transcript = model.store.transcripts.first(where: { $0.id == model.selectedID }) {
            TranscriptDetailView(transcript: transcript)
        } else if model.store.transcripts.isEmpty {
            ContentUnavailableView("Drop an audio file here to transcribe it", systemImage: "waveform.badge.plus")
        } else {
            ContentUnavailableView("Select a transcript or drop an audio file", systemImage: "doc.text")
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { transcriptToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    transcriptToDelete = nil
                }
            }
        )
    }
}

/// One row of the transcript list: file name, creation time, and a line with the status or the start of the text.
private struct TranscriptRow: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(transcript.sourceFileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        switch transcript.status {
        case .inProgress:
            guard transcript.progress > 0 else { return transcript.statusMessage }
            return "\(transcript.statusMessage) \(transcript.progress.formatted(.percent))"
        case .failed:
            return "Failed"
        case .done:
            let preview = transcript.text.prefix(80)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return preview.isEmpty ? "No speech detected" : preview
        }
    }
}
