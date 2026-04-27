@testable import Typeflux
import XCTest

final class SettingsStorePersonaTests: XCTestCase {
    func testBuiltInPersonasDeclareExpectedLanguageModes() throws {
        let suiteName = "SettingsStorePersonaTests.languageModes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)

        let typefluxPersona = try XCTUnwrap(store.personas.first(where: { $0.name == "Typeflux" }))
        XCTAssertTrue(typefluxPersona.prompt.contains("Persona language mode: inherit."))
        XCTAssertTrue(typefluxPersona.prompt.contains("Do not decide the output language on your own."))

        let translatorPersona = try XCTUnwrap(store.personas.first(where: { $0.name == "English Translator" }))
        XCTAssertTrue(translatorPersona.prompt.contains("Persona language mode: fixed English."))
        XCTAssertTrue(translatorPersona.prompt.contains("always produce the final output in natural English"))
    }

    func testResolvedTypefluxPersonaUsesAppLanguagePrompt() throws {
        let suiteName = "SettingsStorePersonaTests.localizedTypeflux.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = .simplifiedChinese

        let typefluxPersona = try XCTUnwrap(store.personas.first(where: { $0.name == "Typeflux" }))
        let prompt = store.resolvedPersonaPrompt(for: typefluxPersona)

        XCTAssertTrue(prompt.contains("人设语言模式：继承。"))
        XCTAssertTrue(prompt.contains("把原始口述内容整理成可直接使用的文字"))
        XCTAssertFalse(prompt.contains("You are Typeflux AI"))
    }

    func testResolvedEnglishTranslatorPersonaUsesLocalizedInstructionButKeepsFixedEnglishOutput() throws {
        let suiteName = "SettingsStorePersonaTests.localizedTranslator.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = .simplifiedChinese

        let translatorPersona = try XCTUnwrap(store.personas.first(where: { $0.name == "English Translator" }))
        let prompt = store.resolvedPersonaPrompt(for: translatorPersona)

        XCTAssertTrue(prompt.contains("人设语言模式：固定英文。"))
        XCTAssertTrue(prompt.contains("最终输出必须始终是自然、流畅的英文"))
        XCTAssertTrue(prompt.contains("翻译成地道英文"))
    }

    func testActivePersonaPromptUsesResolvedSystemPrompt() throws {
        let suiteName = "SettingsStorePersonaTests.activeLocalized.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = .simplifiedChinese

        store.applyPersonaSelection(SettingsStore.defaultPersonaID)

        XCTAssertTrue(store.activePersonaPrompt?.contains("人设语言模式：继承。") == true)
    }

    func testPersonasAlwaysIncludeSystemProfilesAndPersistOnlyCustomProfiles() throws {
        let suiteName = "SettingsStorePersonaTests.persistOnlyCustom.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)

        let customPersona = PersonaProfile(name: "Custom", prompt: "Custom prompt")
        store.personas = store.personas + [customPersona]

        let personas = store.personas

        XCTAssertEqual(personas.filter(\.isSystem).count, 2)
        XCTAssertTrue(personas.contains(where: { $0.id == customPersona.id && !$0.isSystem }))

        let stored = try XCTUnwrap(store.personasJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode([PersonaProfile].self, from: stored)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, customPersona.id)
        XCTAssertEqual(decoded.first?.kind, .custom)
    }

    func testLegacyStoredBuiltInProfilesAreNormalizedWithoutDuplicates() throws {
        let suiteName = "SettingsStorePersonaTests.legacyNormalization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)

        let legacyBuiltIn = PersonaProfile(
            id: UUID(),
            name: "Professional Assistant",
            prompt: "Rewrite in professional, clear, and concise Chinese. Improve sentence flow, preserve key information, and make it suitable to send directly to colleagues or clients.",
        )
        let legacyCustom = PersonaProfile(
            id: UUID(),
            name: "Founder Voice",
            prompt: "Rewrite in a calm founder tone.",
        )

        let data = try JSONEncoder().encode([legacyBuiltIn, legacyCustom])
        store.personasJSON = String(decoding: data, as: UTF8.self)

        let personas = store.personas

        XCTAssertEqual(personas.filter(\.isSystem).count, 2)
        XCTAssertEqual(personas.count(where: { $0.name == legacyBuiltIn.name }), 1)
        XCTAssertTrue(personas.contains(where: { $0.name == legacyCustom.name && !$0.isSystem }))
    }
}
