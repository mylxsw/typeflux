import Carbon.HIToolbox
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskLauncherInputSourceTests {
    @Test func `preference defaults to none and persists source ID`() throws {
        let suite = "launcher-input-source-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askLauncherInputSourceID.isEmpty)
        settings.askLauncherInputSourceID = "com.example.input-method"
        #expect(SettingsStore(defaults: defaults).askLauncherInputSourceID == "com.example.input-method")
        settings.askLauncherInputSourceID = ""
        #expect(SettingsStore(defaults: defaults).askLauncherInputSourceID.isEmpty)
        defaults.set(42, forKey: "ask.launcher.inputSourceID")
        #expect(settings.askLauncherInputSourceID.isEmpty)
    }

    @Test func `catalog only lists enabled selectable keyboard sources and selects exact ID`() throws {
        var selected: [String] = []
        // Read the real catalog, but intercept selection so tests never change the user's input method.
        let selector = SystemAskLauncherInputSourceSelector(selectSource: { source in
            selected.append(Self.stringProperty(kTISPropertyInputSourceID, of: source))
        })
        let sources = selector.availableSources()
        let first = try #require(sources.first)
        #expect(sources.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
        #expect(Set(sources.map(\.id)).count == sources.count)
        let rawSources = try #require(TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource])
        for entry in sources {
            let raw = try #require(rawSources
                .first { Self.stringProperty(kTISPropertyInputSourceID, of: $0) == entry.id })
            #expect(Self
                .stringProperty(kTISPropertyInputSourceCategory, of: raw) == kTISCategoryKeyboardInputSource as String)
            #expect(Self.stringProperty(kTISPropertyLocalizedName, of: raw) == entry.name)
            for key in try [
                #require(kTISPropertyInputSourceIsEnabled),
                #require(kTISPropertyInputSourceIsSelectCapable)
            ] {
                let pointer = try #require(TISGetInputSourceProperty(raw, key))
                #expect(CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()))
            }
        }
        selector.select(sourceID: "")
        selector.select(sourceID: "typeflux.test.nonexistent-input-source")
        #expect(selected.isEmpty)
        selector.select(sourceID: first.id)
        #expect(selected == [first.id])
        let last = try #require(sources.last)
        selector.select(sourceID: last.id)
        #expect(selected == [first.id, last.id])
    }

    @Test func `disabled or removed saved source does not fall back or enable anything`() throws {
        let rawSources = try #require(TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource])
        let source = try #require(rawSources.first)
        let sourceID = Self.stringProperty(kTISPropertyInputSourceID, of: source)
        var enabledSources = [source]
        var selections = 0
        let selector = SystemAskLauncherInputSourceSelector(inputSources: { enabledSources }, selectSource: { _ in
            selections += 1
        })
        #expect(selector.availableSources().count == 1)
        selector.select(sourceID: sourceID)
        #expect(selections == 1)
        enabledSources = []
        #expect(selector.availableSources().isEmpty)
        selector.select(sourceID: sourceID)
        #expect(selections == 1)
    }

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
