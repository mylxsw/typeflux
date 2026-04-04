import XCTest
@testable import Typeflux

final class AppPreferencesTests: XCTestCase {

    // MARK: - STTProvider

    func testSTTProviderDisplayNamesAreNonEmpty() {
        for provider in STTProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) displayName should not be empty")
        }
    }

    func testSTTProviderSettingsDisplayOrderContainsAllCasesExceptAppleSpeech() {
        let displayed = Set(STTProvider.settingsDisplayOrder)
        for provider in STTProvider.allCases {
            if provider == .appleSpeech {
                XCTAssertFalse(displayed.contains(provider))
            } else {
                XCTAssertTrue(displayed.contains(provider), "\(provider) should be in settingsDisplayOrder")
            }
        }
    }

    func testMultimodalLLMHandlesPersonaInternally() {
        XCTAssertTrue(STTProvider.multimodalLLM.handlesPersonaInternally)
    }

    func testOtherSTTProvidersDoNotHandlePersonaInternally() {
        let others = STTProvider.allCases.filter { $0 != .multimodalLLM }
        for provider in others {
            XCTAssertFalse(provider.handlesPersonaInternally, "\(provider) should not handle persona internally")
        }
    }

    // MARK: - LocalSTTModel

    func testLocalSTTModelDisplayNamesAreNonEmpty() {
        for model in LocalSTTModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty, "\(model) displayName should not be empty")
        }
    }

    func testLocalSTTModelDefaultIdentifiers() {
        XCTAssertEqual(LocalSTTModel.whisperLocal.defaultModelIdentifier, "whisperkit-small")
        XCTAssertEqual(LocalSTTModel.senseVoiceSmall.defaultModelIdentifier, "sensevoice-small-coreml")
        XCTAssertTrue(LocalSTTModel.qwen3ASR.defaultModelIdentifier.contains("Qwen3-ASR"))
    }

    func testLocalSTTModelSpecsAreNonEmpty() {
        for model in LocalSTTModel.allCases {
            let specs = model.specs
            XCTAssertFalse(specs.summary.isEmpty, "\(model) summary should not be empty")
            XCTAssertFalse(specs.parameterValue.isEmpty, "\(model) parameterValue should not be empty")
            XCTAssertFalse(specs.sizeValue.isEmpty, "\(model) sizeValue should not be empty")
        }
    }

    // MARK: - LLMProvider

    func testLLMProviderRawValues() {
        XCTAssertEqual(LLMProvider.openAICompatible.rawValue, "openAICompatible")
        XCTAssertEqual(LLMProvider.ollama.rawValue, "ollama")
    }

    func testLLMProviderDisplayNamesAreNonEmpty() {
        for provider in LLMProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) displayName should not be empty")
        }
    }

    // MARK: - AppearanceMode

    func testAppearanceModeRawValues() {
        XCTAssertEqual(AppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "dark")
    }

    func testAppearanceModeDisplayNamesAreNonEmpty() {
        for mode in AppearanceMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) displayName should not be empty")
        }
    }

    // MARK: - PersonaProfile

    func testPersonaProfileIsSystem() {
        let system = PersonaProfile(name: "Default", prompt: "Be helpful", kind: .system)
        XCTAssertTrue(system.isSystem)

        let custom = PersonaProfile(name: "My Style", prompt: "Be concise")
        XCTAssertFalse(custom.isSystem)
    }

    func testPersonaProfileCodableRoundTrip() throws {
        let profile = PersonaProfile(name: "Formal", prompt: "Write formally", kind: .custom)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PersonaProfile.self, from: data)

        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, "Formal")
        XCTAssertEqual(decoded.prompt, "Write formally")
        XCTAssertEqual(decoded.kind, .custom)
    }

    func testPersonaProfileDecodesWithMissingKindAsCustom() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Legacy",
            "prompt": "Be casual"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(PersonaProfile.self, from: data)

        XCTAssertEqual(decoded.kind, .custom)
    }

    func testPersonaProfileEquality() {
        let id = UUID()
        let a = PersonaProfile(id: id, name: "A", prompt: "pa", kind: .custom)
        let b = PersonaProfile(id: id, name: "A", prompt: "pa", kind: .custom)
        XCTAssertEqual(a, b)
    }

    // MARK: - ModelDownloadSource

    func testModelDownloadSourceDisplayNamesAreNonEmpty() {
        for source in ModelDownloadSource.allCases {
            XCTAssertFalse(source.displayName.isEmpty, "\(source) displayName should not be empty")
        }
    }

    // MARK: - PersonaProfileKind

    func testPersonaProfileKindRawValues() {
        XCTAssertEqual(PersonaProfileKind.system.rawValue, "system")
        XCTAssertEqual(PersonaProfileKind.custom.rawValue, "custom")
    }
}
