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

// MARK: - Extended AppPreferences tests

extension AppPreferencesTests {

    // MARK: - STTProvider

    func testSTTProviderAllCasesCount() {
        XCTAssertGreaterThan(STTProvider.allCases.count, 0)
    }

    func testSTTProviderRawValueRoundTrip() {
        for provider in STTProvider.allCases {
            let raw = provider.rawValue
            let recovered = STTProvider(rawValue: raw)
            XCTAssertEqual(recovered, provider)
        }
    }

    func testSTTProviderDisplayNamesAreNonEmpty() {
        for provider in STTProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) should have a non-empty display name")
        }
    }

    func testLocalModelProviderHandlesPersonaInternally() {
        // localModel does NOT handle persona internally (it's just transcription)
        XCTAssertFalse(STTProvider.localModel.handlesPersonaInternally)
    }

    func testWhisperAPIHandlesPersonaInternally() {
        XCTAssertFalse(STTProvider.whisperAPI.handlesPersonaInternally)
    }

    // MARK: - LocalSTTModel

    func testLocalSTTModelAllCasesCount() {
        XCTAssertGreaterThan(LocalSTTModel.allCases.count, 0)
    }

    func testLocalSTTModelRawValueRoundTrip() {
        for model in LocalSTTModel.allCases {
            let raw = model.rawValue
            let recovered = LocalSTTModel(rawValue: raw)
            XCTAssertEqual(recovered, model)
        }
    }

    func testLocalSTTModelDisplayNamesAreNonEmpty() {
        for model in LocalSTTModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty, "\(model) should have a non-empty display name")
        }
    }

    func testLocalSTTModelDefaultModelIdentifierIsNonEmpty() {
        for model in LocalSTTModel.allCases {
            XCTAssertFalse(model.defaultModelIdentifier.isEmpty, "\(model) should have a non-empty default model identifier")
        }
    }

    func testLocalSTTModelSpecsAreValid() {
        for model in LocalSTTModel.allCases {
            let specs = model.specs
            XCTAssertGreaterThan(specs.diskGB, 0, "\(model) should have positive disk requirement")
            XCTAssertGreaterThan(specs.ramGB, 0, "\(model) should have positive RAM requirement")
        }
    }

    // MARK: - LLMProvider

    func testLLMProviderRawValueRoundTrip() {
        for provider in LLMProvider.allCases {
            let raw = provider.rawValue
            let recovered = LLMProvider(rawValue: raw)
            XCTAssertEqual(recovered, provider)
        }
    }

    func testLLMProviderDisplayNamesAreNonEmpty() {
        for provider in LLMProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) should have a non-empty display name")
        }
    }

    // MARK: - AppearanceMode

    func testAppearanceModeRawValueRoundTrip() {
        for mode in AppearanceMode.allCases {
            let raw = mode.rawValue
            let recovered = AppearanceMode(rawValue: raw)
            XCTAssertEqual(recovered, mode)
        }
    }

    func testAppearanceModeDisplayNamesAreNonEmpty() {
        for mode in AppearanceMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) should have a non-empty display name")
        }
    }

    // MARK: - PersonaProfile

    func testPersonaProfileDefaultKindIsCustom() {
        let profile = PersonaProfile(name: "Test", prompt: "Be helpful")
        XCTAssertEqual(profile.kind, .custom)
    }

    func testPersonaProfileInitWithAllParameters() {
        let id = UUID()
        let profile = PersonaProfile(id: id, name: "Formal", prompt: "Write formally", kind: .system)
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.name, "Formal")
        XCTAssertEqual(profile.prompt, "Write formally")
        XCTAssertEqual(profile.kind, .system)
        XCTAssertTrue(profile.isSystem)
    }

    func testPersonaProfileUniqueIDsPerInstance() {
        let p1 = PersonaProfile(name: "A", prompt: "a")
        let p2 = PersonaProfile(name: "B", prompt: "b")
        XCTAssertNotEqual(p1.id, p2.id)
    }

    func testPersonaProfileInequalityOnName() {
        let id = UUID()
        let a = PersonaProfile(id: id, name: "A", prompt: "p", kind: .custom)
        let b = PersonaProfile(id: id, name: "B", prompt: "p", kind: .custom)
        XCTAssertNotEqual(a, b)
    }
}
