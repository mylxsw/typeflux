import XCTest
@testable import Typeflux

final class SettingsStorePersonaTests: XCTestCase {
    func testPersonasAlwaysIncludeSystemProfilesAndPersistOnlyCustomProfiles() throws {
        let suiteName = "SettingsStorePersonaTests.persistOnlyCustom.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
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
        let defaults = UserDefaults(suiteName: suiteName)!
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
        XCTAssertEqual(personas.filter { $0.name == legacyBuiltIn.name }.count, 1)
        XCTAssertTrue(personas.contains(where: { $0.name == legacyCustom.name && !$0.isSystem }))
    }
}
