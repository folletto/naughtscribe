import SwiftUI

@main
struct NaughtScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    /// One model for the whole process: it owns the transcript store and the transcription queue.
    @State private var model = AppModel()

    var body: some Scene {
        // A single window: openWindow(id:) brings it forward when it is already open, and reopens it when closed.
        Window("NaughtScribe", id: "main") {
            ContentView()
                .environment(model)
                .onAppear {
                    appDelegate.openFiles = { urls in
                        _ = model.importFiles(urls)
                    }
                    appDelegate.showMainWindow = {
                        openWindow(id: "main")
                    }
                }
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
        }
    }
}
