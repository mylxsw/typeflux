import Foundation
import SwiftUI
import Testing
@testable import TypefluxIOS

@MainActor
@Suite("Mobile settings preferences")
struct ChatPreferencesTests {
    @Test func `new and unrecognized preferences follow system appearance`() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ChatPreferences(defaults: defaults)
        #expect(preferences.appearance == .system)
        #expect(preferences.appearance.colorScheme == nil)
        defaults.set("unknown-mode", forKey: ChatPreferences.appearanceKey)
        #expect(ChatPreferences(defaults: defaults).appearance == .system)
    }

    @Test func `appearance persists across independent settings instances`() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ChatPreferences(defaults: defaults)
        for appearance in [ChatAppearance.dark, .light, .system] {
            preferences.appearance = appearance
            #expect(defaults.string(forKey: ChatPreferences.appearanceKey) == appearance.rawValue)
            #expect(ChatPreferences(defaults: defaults).appearance == appearance)
        }
        preferences.appearance = .system
        #expect(defaults.string(forKey: ChatPreferences.appearanceKey) == "system")
        #expect(ChatAppearance.light.colorScheme == .light)
        #expect(ChatAppearance.dark.colorScheme == .dark)
    }

    @Test func `reset only clears appearance and leaves unrelated preferences intact`() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("dark", forKey: ChatPreferences.appearanceKey)
        defaults.set("preserve-me", forKey: "unrelated-setting")
        let reset = ChatPreferences(defaults: defaults, resetAppearance: true)
        #expect(reset.appearance == .system)
        #expect(defaults.object(forKey: ChatPreferences.appearanceKey) == nil)
        #expect(defaults.string(forKey: "unrelated-setting") == "preserve-me")
    }

    @Test func `synthetic launches are clean by default and explicitly support persistence checks`() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        ChatPreferences(defaults: defaults).appearance = .dark
        let retained = ChatPreferences.synthetic(arguments: ["--synthetic-preserve-settings"], defaults: defaults)
        #expect(retained.appearance == .dark)
        let clean = ChatPreferences.synthetic(arguments: ["--synthetic-preview"], defaults: defaults)
        #expect(clean.appearance == .system)
        clean.appearance = .light
        #expect(ChatPreferences.synthetic(arguments: [], defaults: defaults).appearance == .system)
        #expect(ChatPreferences.syntheticDomain != Bundle.main.bundleIdentifier)
    }

    @Test func `appearance titles distinguish light mode from light reasoning`() {
        #expect(Set(ChatAppearance.allCases.map(\.title)).count == 3)
        #expect(ChatAppearance.allCases.allSatisfy { !$0.title.isEmpty && $0.id == $0.rawValue })
    }

    @Test func `language names reflect the bundled localization rather than regional locale`() {
        #expect(ChatSettingsInfo.languageName(preferredLocalizations: ["zh-Hans", "en"]) == "简体中文")
        #expect(ChatSettingsInfo.languageName(preferredLocalizations: ["zh-Hans-CN"]) == "简体中文")
        #expect(ChatSettingsInfo.languageName(preferredLocalizations: ["en", "zh-Hans"]) == "English")
        #expect(ChatSettingsInfo.languageName(preferredLocalizations: []) == "English")
    }

    @Test func `version displays supplied bundle metadata without inventing missing values`() {
        #expect(ChatSettingsInfo.version(shortVersion: "0.1.0", build: "12") == "0.1.0 (12)")
        #expect(ChatSettingsInfo.version(shortVersion: " 0.1.0 ", build: " 12 ") == "0.1.0 (12)")
        #expect(ChatSettingsInfo.version(shortVersion: "0.1.0", build: nil) == "0.1.0")
        #expect(ChatSettingsInfo.version(shortVersion: nil, build: "12") == "12")
        #expect(ChatSettingsInfo.version(shortVersion: nil, build: nil) == "—")
        #expect(ChatSettingsInfo.version(shortVersion: " ", build: " ") == "—")
        #expect(!ChatSettingsInfo.version.isEmpty)
        #expect(ChatSettingsInfo.privacyURL.absoluteString == "https://typeflux.app/privacy")
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let domain = "ChatPreferencesTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        return (defaults, domain)
    }
}
