import Foundation
import Speech
import Testing
import TranscriptionCore
@testable import EngineSFSpeech

struct SFSpeechRecognizerEngineTests {
    @Test func descriptorIdentifiesTheLegacyEngine() {
        let descriptor = SFSpeechRecognizerEngine().descriptor
        #expect(descriptor.id == "apple.sfspeech")
        #expect(descriptor.name == "Apple Speech (Legacy)")
        // The SpeechAnalyzer engine has priority 0, so this engine is only tried after it.
        #expect(descriptor.priority == 10)
        #expect(descriptor.priority > 0)
    }
}

struct SFSpeechSegmentTests {
    @Test func textIsTrimmedAndTheSegmentRunsFromTheFirstWordStartToTheLastWordEnd() {
        let words: [(timestamp: TimeInterval, duration: TimeInterval)] = [
            (timestamp: 1, duration: 0.5),
            (timestamp: 1.5, duration: 0.25),
            (timestamp: 2, duration: 0.75),
        ]
        let segment = SFSpeechRecognizerEngine.segment(text: "  Hello brave world \n", wordTimes: words)
        #expect(segment == TranscriptSegment(text: "Hello brave world", start: 1, end: 2.75))
    }

    @Test func aSegmentWithoutWordsHasNoTimes() {
        let segment = SFSpeechRecognizerEngine.segment(text: "Hi", wordTimes: [])
        #expect(segment == TranscriptSegment(text: "Hi", start: nil, end: nil))
    }

    @Test func emptyOrBlankTextMakesNoSegment() {
        let words: [(timestamp: TimeInterval, duration: TimeInterval)] = [(timestamp: 0, duration: 1)]
        #expect(SFSpeechRecognizerEngine.segment(text: "", wordTimes: words) == nil)
        #expect(SFSpeechRecognizerEngine.segment(text: " \n\t ", wordTimes: words) == nil)
    }

    @Test func nonFiniteTimesBecomeNil() {
        // An infinite duration makes the end infinite, so the end is dropped and the start is kept.
        let infiniteDuration: [(timestamp: TimeInterval, duration: TimeInterval)] = [
            (timestamp: 0.5, duration: .infinity),
        ]
        let infiniteEnd = SFSpeechRecognizerEngine.segment(text: "Hi", wordTimes: infiniteDuration)
        #expect(infiniteEnd == TranscriptSegment(text: "Hi", start: 0.5, end: nil))

        // A NaN start makes both the start and the end nil.
        let nanStart: [(timestamp: TimeInterval, duration: TimeInterval)] = [(timestamp: .nan, duration: 0.2)]
        let notANumber = SFSpeechRecognizerEngine.segment(text: "Hi", wordTimes: nanStart)
        #expect(notANumber == TranscriptSegment(text: "Hi", start: nil, end: nil))
    }
}

struct SFSpeechProgressTests {
    @Test func progressStaysBetweenZeroAndJustBelowOne() {
        #expect(SFSpeechRecognizerEngine.clampedProgress(-0.2) == 0)
        #expect(SFSpeechRecognizerEngine.clampedProgress(0.5) == 0.5)
        // Completion is reported only when the job finishes, so progress stops at 0.99.
        #expect(SFSpeechRecognizerEngine.clampedProgress(1.4) == 0.99)
    }

    @Test func nonFiniteProgressIsZero() {
        #expect(SFSpeechRecognizerEngine.clampedProgress(.nan) == 0)
        #expect(SFSpeechRecognizerEngine.clampedProgress(.infinity) == 0)
        #expect(SFSpeechRecognizerEngine.clampedProgress(-.infinity) == 0)
    }
}

struct SFSpeechFailureTests {
    @Test func noSpeechErrorIsRecognizedByItsDomainAndCode() {
        #expect(SFSpeechRecognizerEngine.isNoSpeechError(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        #expect(!SFSpeechRecognizerEngine.isNoSpeechError(NSError(domain: "kAFAssistantErrorDomain", code: 1111)))
        #expect(!SFSpeechRecognizerEngine.isNoSpeechError(NSError(domain: NSCocoaErrorDomain, code: 1110)))
    }

    @Test func onlyAuthorizedSpeechRecognitionLetsTheEngineRun() {
        #expect(SFSpeechRecognizerEngine.authorizationError(for: .authorized) == nil)
        for status in [SFSpeechRecognizerAuthorizationStatus.denied, .restricted, .notDetermined] {
            #expect(isEngineUnavailable(SFSpeechRecognizerEngine.authorizationError(for: status)))
        }
    }
}

struct SFSpeechLocaleTests {
    @Test func aSpecificLanguageIsUsedAsItIsAndAutomaticUsesTheSystemLocale() {
        let german = Locale(identifier: "de_DE")
        #expect(SFSpeechRecognizerEngine.requestedLocale(for: .specific(german)) == german)
        #expect(SFSpeechRecognizerEngine.requestedLocale(for: .automatic) == Locale.current)
    }

    @Test func anIdenticalIdentifierIsTheMatch() {
        let candidates = [Locale(identifier: "fr_FR"), Locale(identifier: "fr_CA")]
        let match = SFSpeechRecognizerEngine.bestMatch(for: Locale(identifier: "fr_CA"), among: candidates)
        #expect(match == Locale(identifier: "fr_CA"))
    }

    @Test func aLanguageInAnotherRegionFallsBackToTheFirstIdentifierInAnyOrder() {
        // No English candidate is in Italy, so the English candidate that sorts first is used.
        let candidates = [Locale(identifier: "en_GB"), Locale(identifier: "en_US"), Locale(identifier: "it_IT")]
        let reordered = [Locale(identifier: "it_IT"), Locale(identifier: "en_US"), Locale(identifier: "en_GB")]
        let requested = Locale(identifier: "en_IT")
        #expect(SFSpeechRecognizerEngine.bestMatch(for: requested, among: candidates) == Locale(identifier: "en_GB"))
        #expect(SFSpeechRecognizerEngine.bestMatch(for: requested, among: reordered) == Locale(identifier: "en_GB"))
    }

    @Test func keywordsAreIgnoredWhenMatchingTheRegion() {
        let candidates = [Locale(identifier: "en_GB"), Locale(identifier: "en_US"), Locale(identifier: "it_IT")]
        let requested = Locale(identifier: "en_US@rg=itzzzz")
        #expect(SFSpeechRecognizerEngine.bestMatch(for: requested, among: candidates) == Locale(identifier: "en_US"))
    }

    @Test func aLanguageWithNoCandidateHasNoMatch() {
        let candidates = [Locale(identifier: "en_US")]
        #expect(SFSpeechRecognizerEngine.bestMatch(for: Locale(identifier: "de_DE"), among: candidates) == nil)
    }
}

// MARK: - Helpers

/// Whether `error` is `.engineUnavailable`, whatever its reason.
private func isEngineUnavailable(_ error: TranscriptionError?) -> Bool {
    if case .engineUnavailable? = error {
        return true
    }
    return false
}
