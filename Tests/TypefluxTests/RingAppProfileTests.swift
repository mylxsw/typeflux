import AppKit
@testable import Typeflux
import XCTest

/// Per-app actions: storage, Settings → Ring's scopes, the library's app shortcuts and the tab row.
@MainActor
final class RingAppProfileTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "RingAppProfileTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    func profile(_ bundle: String, enabled: Bool = true,
                 actions: [RingAction] = [.feature(.notes)]) -> RingAppProfile {
        RingAppProfile(bundleIdentifier: bundle, appName: bundle.components(separatedBy: ".").last ?? bundle,
                       isEnabled: enabled, actions: actions)
    }

    // MARK: - Configuration

    func testProfileLookupNeedsAnEnabledProfileWithActions() {
        var configuration = RingConfiguration()
        configuration.appProfiles = [profile("com.apple.Safari"), profile("com.figma.Desktop", enabled: false),
                                     profile("com.apple.mail", actions: [])]
        XCTAssertEqual(configuration.profile(forBundleIdentifier: "com.apple.Safari")?.appName, "Safari")
        XCTAssertNil(configuration.profile(forBundleIdentifier: "com.figma.Desktop"), "switched off")
        XCTAssertNil(configuration.profile(forBundleIdentifier: "com.apple.mail"), "nothing to choose")
        XCTAssertNil(configuration.profile(forBundleIdentifier: "com.apple.finder"))
        XCTAssertNil(configuration.profile(forBundleIdentifier: nil))
    }

    func testRingIsUsableWithOnlyAnAppProfile() {
        var configuration = RingConfiguration(actions: [])
        XCTAssertFalse(configuration.isUsable)
        configuration.appProfiles = [profile("com.apple.Safari", enabled: false)]
        XCTAssertFalse(configuration.isUsable)
        configuration.appProfiles = [profile("com.apple.Safari")]
        XCTAssertTrue(configuration.isUsable)
    }

    func testProfilesRoundTripAndOldFilesHaveNone() throws {
        var configuration = RingConfiguration()
        configuration.appProfiles = [profile("com.apple.Safari", enabled: false)]
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(RingConfiguration.self, from: data), configuration)

        let old = Data(#"{"actions":[],"style":"classic"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RingConfiguration.self, from: old).appProfiles, [])
    }

    func testUnreadableProfilesActionsAndDuplicatesAreSkipped() throws {
        let id = UUID()
        let json = """
        {"actions":[],"appProfiles":[
          {"id":"\(id.uuidString)","bundleIdentifier":"com.apple.Safari","actions":[
            {"id":"\(UUID().uuidString)","kind":{"feature":{"_0":"notes"}},"title":"Notes","symbol":"note.text"},
            {"id":"\(UUID().uuidString)","kind":{"teleport":{}},"title":"New","symbol":"star"}]},
          {"bundleIdentifier":"broken"},
          {"id":"\(UUID().uuidString)","bundleIdentifier":"com.apple.Safari","appName":"Again","actions":[]}
        ]}
        """
        let decoded = try JSONDecoder().decode(RingConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.appProfiles.count, 1, "a profile without an id is skipped, a second Safari too")
        let safari = try XCTUnwrap(decoded.appProfiles.first)
        XCTAssertEqual(safari.id, id)
        XCTAssertEqual(safari.appName, "com.apple.Safari", "a missing name falls back to the bundle identifier")
        XCTAssertTrue(safari.isEnabled, "a missing switch means on")
        XCTAssertEqual(safari.actions.map(\.kind), [.feature(.notes)], "an action from a newer version is skipped")
    }

    func testProfilesKeepAtMostEightActions() {
        let many = (0 ..< 12).map { _ in RingAction.feature(.notes) }
        XCTAssertEqual(RingAppProfile(bundleIdentifier: "a", appName: "A", actions: many).actions.count,
                       RingConfiguration.maxActions)
    }

    func testLegacyChatTitlesAreMigratedInProfilesToo() {
        var configuration = RingConfiguration(actions: [])
        configuration.appProfiles = [profile("com.apple.Safari",
                                             actions: [RingAction(kind: .feature(.ask), title: "Ask", symbol: "x")])]
        XCTAssertTrue(configuration.migrateLegacyChatTitles())
        XCTAssertEqual(configuration.appProfiles[0].actions[0].title, RingFeature.ask.title)
        XCTAssertFalse(configuration.migrateLegacyChatTitles())
    }

    // MARK: - Settings model

    func testEditsApplyToTheSelectedScopeOnly() throws {
        let model = RingSettingsModel(settingsStore: store)
        let global = model.actions
        let id = model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        XCTAssertEqual(model.scope, .app(id))
        XCTAssertEqual(model.actions, [])
        XCTAssertTrue(model.insert(.feature(.notes), at: 0))
        let notes = try XCTUnwrap(model.actions.first)
        model.edit(notes.id) { $0.title = "Mine" }
        XCTAssertNotNil(model.duplicate(notes.id))
        model.move(notes.id, by: 1)
        XCTAssertEqual(model.actions.map(\.title), ["Mine", "Mine"])
        model.delete(notes.id)
        XCTAssertEqual(store.ringConfiguration.appProfiles[0].actions.count, 1, "saved at once")
        XCTAssertEqual(store.ringConfiguration.actions, global, "global actions untouched")

        model.resetActions()
        XCTAssertEqual(model.actions.count, 1, "an app has no defaults to restore")
        model.select(.global)
        XCTAssertEqual(model.actions, global)
    }

    func testCanAddActionFollowsTheScope() {
        let model = RingSettingsModel(settingsStore: store)
        for feature in [RingFeature.notes, .wordBook] {
            XCTAssertTrue(model.insert(.feature(feature), at: 0))
        }
        XCTAssertFalse(model.canAddAction, "the global ring is full")
        model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        XCTAssertTrue(model.canAddAction)
        XCTAssertTrue(model.insert(.feature(.notes), at: 0))
    }

    func testAddingAnAppTwiceSelectsTheExistingProfile() {
        let model = RingSettingsModel(settingsStore: store)
        let first = model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        model.select(.global)
        XCTAssertEqual(model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari 2"), first)
        XCTAssertEqual(model.scope, .app(first))
        XCTAssertEqual(store.ringConfiguration.appProfiles.count, 1)
    }

    func testSelectingAMissingProfileFallsBackToGlobal() {
        let model = RingSettingsModel(settingsStore: store)
        model.select(.app(UUID()))
        XCTAssertEqual(model.scope, .global)
        XCTAssertNil(model.profile)
    }

    func testRemovingAProfileElsewhereReturnsToGlobal() {
        let model = RingSettingsModel(settingsStore: store)
        model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        var configuration = store.ringConfiguration
        configuration.appProfiles = []
        store.ringConfiguration = configuration
        XCTAssertEqual(model.scope, .global)
    }

    func testCopyGlobalGivesNewIDsAndCanBeUndone() {
        let model = RingSettingsModel(settingsStore: store)
        let id = model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        model.copyGlobalActions(into: id)
        let copied = model.actions
        XCTAssertEqual(copied.map(\.kind), store.ringConfiguration.actions.map(\.kind))
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: store.ringConfiguration.actions.map(\.id)))
        XCTAssertEqual(model.lastChange, L("ring.undo.copiedGlobal", copied.count))
        model.undo()
        XCTAssertEqual(model.actions, [])

        model.copyGlobalActions(into: UUID())
        XCTAssertEqual(model.actions, [], "an unknown profile is ignored")
    }

    func testCopyGlobalDoesNothingWithoutGlobalActions() {
        var configuration = store.ringConfiguration
        configuration.actions = []
        store.ringConfiguration = configuration
        let model = RingSettingsModel(settingsStore: store)
        let id = model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        model.copyGlobalActions(into: id)
        XCTAssertEqual(model.actions, [])
        XCTAssertEqual(model.lastChange, L("ring.undo.addedApp", "Safari"))
    }

    func testRemovingAndAddingAppsCanBeUndoneAndUndoShowsWhereItHappened() {
        let model = RingSettingsModel(settingsStore: store)
        let id = model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        XCTAssertTrue(model.insert(.feature(.notes), at: 0))
        model.removeProfile(id)
        XCTAssertEqual(model.scope, .global)
        XCTAssertEqual(model.lastChange, L("ring.undo.removedApp", "Safari"))
        XCTAssertTrue(store.ringConfiguration.appProfiles.isEmpty)

        model.undo()
        XCTAssertEqual(model.scope, .app(id), "undo shows the app again")
        XCTAssertEqual(model.actions.map(\.kind), [.feature(.notes)])
        model.undo()
        model.undo()
        XCTAssertTrue(store.ringConfiguration.appProfiles.isEmpty, "back to before the app was added")
        XCTAssertEqual(model.scope, .global)
        model.removeProfile(UUID())
        XCTAssertFalse(model.canUndo)
    }

    func testTheSwitchIsNotUndoneByUndo() {
        let model = RingSettingsModel(settingsStore: store)
        let id = model.addProfile(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        XCTAssertTrue(model.insert(.feature(.notes), at: 0))
        model.setProfileEnabled(id, false)
        XCTAssertFalse(store.ringConfiguration.appProfiles[0].isEnabled)
        model.undo()
        XCTAssertEqual(model.actions, [])
        XCTAssertFalse(store.ringConfiguration.appProfiles[0].isEnabled, "the switch stays where it was put")
        model.setProfileEnabled(UUID(), true)
    }
}

/// The library's app shortcuts and the tab row.
extension RingAppProfileTests {
    func testAppShortcutsAreSuggestedFirstAndListedWithKeys() throws {
        let items = RingAppShortcutCatalog.items(for: "com.apple.Safari", appName: "Safari")
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.group == L("ring.library.group.appKeys", "Safari") })
        XCTAssertEqual(items.first?.title, L("ring.appKeys.newTab"))
        XCTAssertTrue(RingAppShortcutCatalog.items(for: "com.example.unknown", appName: "X").isEmpty)
        XCTAssertTrue(RingAppShortcutCatalog.items(for: nil, appName: "").isEmpty)

        let library = RingActionLibrary(appShortcuts: items)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(library.recommendations(excluding: []).first, first)
        let suggested = library.recommendations(excluding: [first.action()])
        XCTAssertFalse(suggested.contains(first), "already on the ring")
        XCTAssertEqual(suggested.count, 4)
        XCTAssertEqual(Array(library.items(of: .keys).prefix(items.count)), items)
        XCTAssertTrue(library.search(first.title).contains { $0.kind == first.kind })

        let all = items.map { $0.action() }
        XCTAssertEqual(library.recommendations(excluding: all).first?.kind, RingActionLibrary.recommended.first,
                       "with every app shortcut on the ring, features are suggested again")
    }

    func testEveryCatalogEntryHasATitle() {
        for (_, entries) in RingAppShortcutCatalog.entries {
            for entry in entries {
                XCTAssertNotEqual(entry.title, "ring.appKeys." + entry.name, entry.name)
            }
        }
    }

    // MARK: - Tab row

    func testTabsThatDoNotFitGoBehindMore() {
        let widths: [CGFloat] = [100, 100, 100, 100]
        XCTAssertEqual(RingScopeBarLayout.visibleIndexes(chipWidths: widths, available: 1000, reserved: 200,
                                                         moreWidth: 80, selected: nil), [0, 1, 2, 3])
        // 200 + 106 + 106 = 412; a third would need 518 + 86 for More.
        XCTAssertEqual(RingScopeBarLayout.visibleIndexes(chipWidths: widths, available: 560, reserved: 200,
                                                         moreWidth: 80, selected: nil), [0, 1])
        XCTAssertEqual(RingScopeBarLayout.visibleIndexes(chipWidths: widths, available: 560, reserved: 200,
                                                         moreWidth: 80, selected: 1), [0, 1])
        XCTAssertEqual(RingScopeBarLayout.visibleIndexes(chipWidths: widths, available: 560, reserved: 200,
                                                         moreWidth: 80, selected: 3), [0, 3],
                       "the selected tab takes the last visible place")
        XCTAssertEqual(RingScopeBarLayout.visibleIndexes(chipWidths: widths, available: 250, reserved: 200,
                                                         moreWidth: 80, selected: 2), [2],
                       "the selected tab shows even when nothing else fits")
        XCTAssertEqual(RingScopeBarLayout.visibleIndexes(chipWidths: widths, available: 250, reserved: 200,
                                                         moreWidth: 80, selected: nil), [])
        XCTAssertEqual(RingScopeBarLayout.visibleIndexes(chipWidths: [], available: 250, reserved: 200,
                                                         moreWidth: 80, selected: 0), [])
        // The last tab needs no room for More.
        XCTAssertEqual(RingScopeBarLayout.visibleIndexes(chipWidths: [100, 100], available: 412, reserved: 200,
                                                         moreWidth: 80, selected: nil), [0, 1])
    }

    func testTabWidthGrowsWithItsText() {
        XCTAssertGreaterThan(RingScopeBarLayout.chipWidth(title: "Visual Studio Code", detail: "8"),
                             RingScopeBarLayout.chipWidth(title: "Mail", detail: "8"))
    }

    func testHiddenAppsAndAppPickerFilter() {
        let profiles = [profile("com.apple.Safari"), profile("com.apple.mail")]
        XCTAssertEqual(RingHiddenAppsList.filtered(profiles, query: "mail").map(\.bundleIdentifier),
                       ["com.apple.mail"])
        XCTAssertEqual(RingHiddenAppsList.filtered(profiles, query: "").count, 2)

        let apps = [RingLibraryApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
                    RingLibraryApp(name: "Mail", bundleIdentifier: "com.apple.mail"),
                    RingLibraryApp(name: "Notes", bundleIdentifier: "com.apple.Notes")]
        let groups = RingAddAppPicker.groups(apps, running: ["com.apple.mail"], query: "")
        XCTAssertEqual(groups.running.map(\.name), ["Mail"])
        XCTAssertEqual(groups.others.map(\.name), ["Safari", "Notes"])
        XCTAssertEqual(RingAddAppPicker.groups(apps, running: [], query: "com.apple.n").others.map(\.name), ["Notes"])
    }

    func testAppIconFallsBackForMissingApps() {
        XCTAssertFalse(RingAppIcon.isInstalled("com.example.not-installed"))
        XCTAssertGreaterThan(RingAppIcon.image(bundleIdentifier: "com.example.not-installed").size.width, 0)
        XCTAssertTrue(RingAppIcon.image(bundleIdentifier: "com.example.not-installed")
            === RingAppIcon.image(bundleIdentifier: "com.example.not-installed"), "cached")
    }
}
