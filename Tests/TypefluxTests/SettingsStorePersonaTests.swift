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
