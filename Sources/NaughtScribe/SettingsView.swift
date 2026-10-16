import Speech
import SwiftUI

/// Settings that the rest of the app reads. The values are stored in UserDefaults through @AppStorage.
enum AppSettings {
    static let transcriptionLanguageKey = "transcriptionLanguage"

    /// The locale to transcribe with: the language chosen in Settings, or the system locale for "System default".
    static func resolvedLocale() -> Locale {
        let stored = UserDefaults.standard.string(forKey: transcriptionLanguageKey) ?? ""
        return stored.isEmpty ? Locale.current : Locale(identifier: stored)
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.transcriptionLanguageKey) private var languageIdentifier = ""
    @State private var languages: [LanguageOption] = []

    var body: some View {
        Form {
            Picker("Transcription language", selection: $languageIdentifier) {
                Text("System default").tag("")
                ForEach(languages) { language in
                    Text(language.name).tag(language.id)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .task { await loadLanguages() }
    }

    /// `SpeechTranscriber.supportedLocales` is async, so the list is loaded here rather than when the view is built.
    private func loadLanguages() async {
        let locales = await SpeechTranscriber.supportedLocales
        let current = Locale.current
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

private struct LanguageOption: Identifiable {
    let id: String
    let name: String
}
