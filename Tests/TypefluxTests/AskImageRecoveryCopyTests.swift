import Foundation
import Testing
@testable import Typeflux

@Suite("Ask image recovery copy")
struct AskImageRecoveryCopyTests {
    private func copy(busy: Bool = false, canResume: Bool = false,
                      capability: AskImageCapability = .unsupported) -> AskImageRecoveryCopy {
        AskImageRecoveryCopy(busy: busy, canResume: canResume, capability: capability, modelName: "Vision")
    }

    @Test func readyModelDoesNotAskForAnotherModel() {
        let value = copy(canResume: true, capability: .supported)
        #expect(value.title == L("ask.image.savedReady"))
        #expect(value.title != L("ask.image.saved"))
        #expect(value.detail == L("ask.image.ready"))
    }

    @Test func incompatibleModelsExplainWhatToDo() {
        #expect(copy(capability: .unsupported).title == L("ask.image.saved"))
        #expect(copy(capability: .unsupported).detail == L("ask.image.recoveryHint"))
        #expect(copy(capability: .unknown).detail == L("ask.image.unknown"))
        #expect(copy(capability: .unavailable).detail == L("ask.models.unavailable"))
        // Supported but not resumable (for example, a sign-in requirement) is
        // treated as unavailable rather than claiming the model is ready.
        #expect(copy(capability: .supported).detail == L("ask.models.unavailable"))
    }

    @Test func busyStateNamesTheModelDoingTheWork() {
        let value = copy(busy: true, canResume: true, capability: .supported)
        #expect(value.title == L("ask.image.resuming"))
        #expect(value.detail == L("ask.image.processing", "Vision"))
        #expect(value.detail.contains("Vision"))
    }

    @Test func everyLocalizationDefinesTheReadyTitle() throws {
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            let ready = bundle.localizedString(forKey: "ask.image.savedReady", value: nil, table: nil)
            let saved = bundle.localizedString(forKey: "ask.image.saved", value: nil, table: nil)
            #expect(ready != "ask.image.savedReady", "Missing ready title for \(language.rawValue)")
            #expect(ready != saved)
        }
    }

    @Test func recoveryCardIsASubordinateSurface() {
        #expect(AskMetrics.recoveryCardCorner < AskMetrics.composerCardCorner)
        #expect(AskMetrics.recoveryThumbnail.width > AskMetrics.recoveryThumbnail.height)
    }
}
