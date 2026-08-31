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
        XCTAssertTrue(translatorPersona.prompt.contains("output only the final English text"))
    }

    func testBuiltInPersonasUseStableCloudIdentifiers() throws {
        let suiteName = "SettingsStorePersonaTests.stableIDs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)

        let typefluxPersona = try XCTUnwrap(store.personas.first(where: { $0.name == "Typeflux" }))
        let translatorPersona = try XCTUnwrap(store.personas.first(where: { $0.name == "English Translator" }))

        XCTAssertEqual(typefluxPersona.id, UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA001"))
        XCTAssertEqual(translatorPersona.id, UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA002"))
        XCTAssertTrue(typefluxPersona.isSystem)
        XCTAssertTrue(translatorPersona.isSystem)
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
        XCTAssertTrue(prompt.contains("去除口头填充词（如 um、uh、like、you know、basically 等）"))
        XCTAssertFalse(prompt.contains("You are Typeflux AI"))
    }

    func testResolvedTypefluxPersonaUsesEnglishPrompt() throws {
        let prompt = try resolvedTypefluxPrompt(appLanguage: .english)

        XCTAssertTrue(prompt.contains("Persona language mode: inherit."))
        XCTAssertTrue(prompt.contains("spoken filler words (such as um, uh, like, you know, basically)"))
        XCTAssertTrue(prompt.contains("Keep the user's overall tone natural"))
        XCTAssertFalse(prompt.contains("人设语言模式"))
    }

    func testResolvedTypefluxPersonaUsesTraditionalChinesePrompt() throws {
        let prompt = try resolvedTypefluxPrompt(appLanguage: .traditionalChinese)

        XCTAssertTrue(prompt.contains("人設語言模式：繼承。"))
        XCTAssertTrue(prompt.contains("去除口語填充詞（如 um、uh、like、you know、basically 等）"))
        XCTAssertTrue(prompt.contains("保持使用者整體語氣自然"))
        XCTAssertFalse(prompt.contains("人设语言模式"))
    }

    func testResolvedTypefluxPersonaUsesJapanesePrompt() throws {
        let prompt = try resolvedTypefluxPrompt(appLanguage: .japanese)

        XCTAssertTrue(prompt.contains("ペルソナの言語モード：継承。"))
        XCTAssertTrue(prompt.contains("口頭のフィラー（um、uh、like、you know、basically など）"))
        XCTAssertTrue(prompt.contains("ユーザーの全体的なトーンを自然に保ち"))
        XCTAssertFalse(prompt.contains("人设语言模式"))
    }

    func testResolvedTypefluxPersonaUsesKoreanPrompt() throws {
        let prompt = try resolvedTypefluxPrompt(appLanguage: .korean)

        XCTAssertTrue(prompt.contains("페르소나 언어 모드: 상속."))
        XCTAssertTrue(prompt.contains("구어 필러(예: um, uh, like, you know, basically)"))
        XCTAssertTrue(prompt.contains("사용자의 전체 어조를 자연스럽게 유지하고"))
        XCTAssertFalse(prompt.contains("人设语言模式"))
    }

    private func resolvedTypefluxPrompt(appLanguage: AppLanguage) throws -> String {
        let suiteName = "SettingsStorePersonaTests.typefluxPrompt.\(appLanguage.rawValue).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = appLanguage

        let typefluxPersona = try XCTUnwrap(store.personas.first(where: { $0.name == "Typeflux" }))
        return store.resolvedPersonaPrompt(for: typefluxPersona)
    }

    func testResolvedEnglishTranslatorPersonaAlwaysUsesEnglishPrompt() throws {
        let suiteName = "SettingsStorePersonaTests.englishTranslatorUnchanged.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = .simplifiedChinese

        let translatorPersona = try XCTUnwrap(store.personas.first(where: { $0.name == "English Translator" }))
        let prompt = store.resolvedPersonaPrompt(for: translatorPersona)

        XCTAssertTrue(prompt.contains("Persona language mode: fixed English."))
        XCTAssertTrue(prompt.contains("output only the final English text"))
        XCTAssertFalse(prompt.contains("人设语言模式"))
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
            prompt: "Rewrite in professional, clear, and concise Chinese. Improve sentence flow, preserve key information, and make it suitable to send directly to colleagues or clients."
        )
        let legacyCustom = PersonaProfile(
            id: UUID(),
            name: "Founder Voice",
            prompt: "Rewrite in a calm founder tone."
        )

        let data = try JSONEncoder().encode([legacyBuiltIn, legacyCustom])
        store.personasJSON = String(decoding: data, as: UTF8.self)

        let personas = store.personas

        XCTAssertEqual(personas.filter(\.isSystem).count, 2)
        XCTAssertEqual(personas.count(where: { $0.name == legacyBuiltIn.name }), 1)
        XCTAssertTrue(personas.contains(where: { $0.name == legacyCustom.name && !$0.isSystem }))
    }
}
