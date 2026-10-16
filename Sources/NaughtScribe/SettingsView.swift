import SwiftUI
import TranscriptionCore

/// Settings that the rest of the app reads. The values are stored in UserDefaults through @AppStorage.
enum AppSettings {
    static let transcriptionEngineKey = "transcriptionEngine"
    static let transcriptionLanguageKey = "transcriptionLanguage"

    /// The engine chosen in Settings, or nil for "Automatic".
    static func preferredEngineID() -> String? {
        let stored = UserDefaults.standard.string(forKey: transcriptionEngineKey) ?? ""
        return stored.isEmpty ? nil : stored
    }

    /// The locale to transcribe with: the language chosen in Settings, or the system locale for "System default".
    static func resolvedLocale() -> Locale {
        let stored = UserDefaults.standard.string(forKey: transcriptionLanguageKey) ?? ""
        return stored.isEmpty ? Locale.current : Locale(identifier: stored)
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.transcriptionEngineKey) private var engineID = ""
    @AppStorage(AppSettings.transcriptionLanguageKey) private var languageIdentifier = ""
    @State private var engines: [EngineOption] = []
    @State private var languages: [LanguageOption] = []
    /// True when no engine can run, so there are no languages to choose from.
    @State private var noEngineAvailable = false

    var body: some View {
        Form {
            Picker("Engine", selection: $engineID) {
                Text("Automatic").tag("")
                ForEach(engines) { engine in
                    Text(engine.name)
                        .disabled(engine.unavailableReason != nil)
                        .tag(engine.id)
                }
            }
            // An engine that cannot run stays listed, together with the reason.
            ForEach(engines) { engine in
                if let reason = engine.unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Transcription language", selection: $languageIdentifier) {
                Text("System default").tag("")
                ForEach(languages) { language in
                    Text(language.name).tag(language.id)
                }
            }
            if noEngineAvailable {
                Text("No transcription engine is available on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .task { await loadEngines() }
        // The languages come from the engine in use, so they are loaded again when the engine choice changes.
        .task(id: engineID) { await loadLanguages() }
    }

    /// Reads whether each engine can run. Engines are listed most preferred first.
    private func loadEngines() async {
        var options: [EngineOption] = []
        for engine in EngineRegistry.shared.sortedEngines() {
            var reason: String?
            if case .unavailable(let text) = await engine.availability() {
                reason = text
            }
            options.append(
                EngineOption(id: engine.descriptor.id, name: engine.descriptor.name, unavailableReason: reason)
            )
        }
        engines = options
    }

    /// Loads the languages of the engine that jobs would use with the current choice. When no engine can run,
    /// the list stays empty and the note is shown instead.
    /// The engine's languages are async, so the list is loaded here rather than when the view is built.
    private func loadLanguages() async {
        guard let engine = await EngineRegistry.shared.resolve(preferredID: AppSettings.preferredEngineID()) else {
            languages = []
            noEngineAvailable = true
            return
        }
        noEngineAvailable = false
        let current = Locale.current
        let locales = await engine.languageSupport().locales
        languages = locales
            .map { locale in
                LanguageOption(
                    id: locale.identifier,
                    name: current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// One engine in the Engine picker. `unavailableReason` is set when the engine cannot run.
private struct EngineOption: Identifiable {
    let id: String
    let name: String
    let unavailableReason: String?
}

private struct LanguageOption: Identifiable {
    let id: String
    let name: String
}
