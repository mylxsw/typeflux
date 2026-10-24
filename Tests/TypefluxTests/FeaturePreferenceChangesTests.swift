import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeaturePreferenceChangesTests {
    @Test func runtimeBookkeepingDoesNotInvalidateTheChatInterface() throws {
        let domain = "preferences-noise-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var changes = FeaturePreferenceChanges(defaults: defaults)
        for index in 0..<50 {
            defaults.set(["fixture.app": Double(index)], forKey: "ask.quickResults.appLastUsed")
            defaults.set("frame-\(index)", forKey: "NSWindow Frame Chat")
            defaults.set(index, forKey: "fixture.unrelated")
            #expect(changes.notifications(in: defaults).isEmpty)
        }
    }

    @Test func eachPreferenceNotifiesOnlyItsConsumersAndRepeatedSyncIsSilent() throws {
        let domain = "preferences-effects-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var changes = FeaturePreferenceChanges(defaults: defaults)
        let cases: [(String, [Notification.Name])] = [
            ("ui.appIconStyle", [.appIconStyleDidChange]),
            ("ui.appearance", [.appearanceModeDidChange]),
            ("ui.language", [.appLanguageDidChange]),
            ("ui.overlayStyle", [.interfaceStyleDidChange]),
            ("ui.liquidGlassIntensity", [.interfaceStyleDidChange]),
            ("agent.mcpServers", [.agentConfigurationDidChange]),
            ("ui.voiceCapsule.style", [.voiceCapsuleDidChange]),
            ("audio.input.preferredMicrophoneID", [.preferredMicrophoneDidChange]),
            ("audio.recording.instantVoiceInput", [.instantVoiceInputDidChange]),
            ("persona.items.guest", [.personaStoreDidChange, .personaSelectionDidChange]),
            ("persona.activeID", [.personaSelectionDidChange]),
            ("ring.configuration.json", [.ringSettingsDidChange]),
            ("clipboard.pausedUntil", [.clipboardRecordingPauseDidChange])
        ]
        for (key, expected) in cases {
            defaults.set("fixture", forKey: key)
            #expect(Set(changes.notifications(in: defaults)) == Set(expected))
            #expect(changes.notifications(in: defaults).isEmpty)
            defaults.removeObject(forKey: key)
            #expect(Set(changes.notifications(in: defaults)) == Set(expected))
        }
    }

    @Test func oneBatchDoesNotRepeatNotificationsForRelatedKeys() throws {
        let domain = "preferences-batch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var changes = FeaturePreferenceChanges(defaults: defaults)
        defaults.set("corner", forKey: "ui.voiceCapsule.style")
        defaults.set("left", forKey: "ui.voiceCapsule.cornerEdge")
        defaults.set("dark", forKey: "ui.appearance")
        #expect(changes.notifications(in: defaults) == [.appearanceModeDidChange, .voiceCapsuleDidChange])
    }

    @Test func selectedIconLoadsAndInstallsOnceWhileDockRecreationCanForceInstall() throws {
        let application = AppIconApplication()
        let artwork = NSImage(size: .init(width: 8, height: 8))
        var loads = 0, installs = 0
        func load(_ style: AppIconStyle) -> NSImage? { loads += 1; return artwork }
        func install(_ image: NSImage?) { installs += 1; #expect(image === artwork) }
        for _ in 0..<1000 { #expect(application.apply(.violetInfinity, load: load, install: install)) }
        #expect(loads == 1 && installs == 1)
        #expect(application.apply(.violetInfinity, force: true, load: load, install: install))
        #expect(loads == 1 && installs == 2)
        var restoredBundle = false
        #expect(application.apply(.glassFrosted, load: load) { restoredBundle = $0 == nil })
        #expect(restoredBundle && loads == 1)
        #expect(application.apply(.glassFrosted, load: load) { _ in installs += 1 })
        #expect(installs == 2)
    }

    @Test func failedIconLoadDoesNotPoisonRetryOrDiscardTheSelectedArtwork() {
        let application = AppIconApplication()
        let artwork = NSImage(size: .init(width: 8, height: 8))
        var installs = 0
        #expect(application.apply(.violetInfinity, load: { _ in artwork }, install: { _ in installs += 1 }))
        #expect(!application.apply(.white, load: { _ in nil }, install: { _ in installs += 1 }))
        #expect(application.apply(.violetInfinity, load: { _ in nil }, install: { _ in installs += 1 }))
        #expect(installs == 1)
        #expect(application.apply(.white, load: { _ in artwork }, install: { _ in installs += 1 }))
        #expect(installs == 2)
    }

    @Test func modelLibraryRetainsItsSettingsFacadeAndStillReadsCurrentPreferences() throws {
        let domain = "model-settings-retained-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let settings = library.settings
        #expect(library.settings === settings)
        defaults.set("fixture-microphone", forKey: "audio.input.preferredMicrophoneID")
        #expect(library.settings.preferredMicrophoneID == "fixture-microphone")
        library.reloadFeaturePreferences()
        #expect(library.settings === settings)
    }
}
