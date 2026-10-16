import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Receives audio files opened from Finder, "Open With" or the Dock. The app sets this once its model exists.
    /// Files that arrive before then are held and delivered as soon as it is set.
    var openFiles: (([URL]) -> Void)? {
        didSet {
            guard let openFiles, !pendingFiles.isEmpty else { return }
            let urls = pendingFiles
            pendingFiles = []
            openFiles(urls)
        }
    }

    /// Brings the main window forward, reopening it if it was closed. The app sets this with `openFiles`.
    var showMainWindow: (() -> Void)?

    private var pendingFiles: [URL] = []

    // Files opened from Finder, "Open With" or dropped on the Dock icon arrive here.
    func application(_ sender: NSApplication, open urls: [URL]) {
        let audioFiles = urls.filter(AudioFileTypes.isSupported)
        guard !audioFiles.isEmpty else { return }
        NSApp.activate()
        showMainWindow?()
        if let openFiles {
            openFiles(audioFiles)
        } else {
            pendingFiles += audioFiles
        }
    }

    // A Dock click with no window open should show the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow?()
        }
        return true
    }
}
