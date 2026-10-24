@testable import Typeflux
import XCTest

final class RingActionLibraryTests: XCTestCase {
    private let keyword = KeywordHotkeyOption(
        keyword: AskKeyword(keyword: "fy", pluginID: "translate"),
        name: "Translate"
    )

    private var library: RingActionLibrary {
        RingActionLibrary(keywords: [keyword],
                          apps: [RingLibraryApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
                                 RingLibraryApp(name: "Notes", bundleIdentifier: "com.apple.Notes")],
                          shortcuts: ["Pomodoro", "Daily Brief"])
    }

    // MARK: - Browsing

    func testEveryTypeHasItsItems() {
        XCTAssertEqual(library.items(of: .feature).map(\.kind), RingFeature.allCases.map { .feature($0) })
        XCTAssertEqual(library.items(of: .system).map(\.kind), RingSystemAction.allCases.map { .system($0) })
        XCTAssertEqual(library.items(of: .keyword).map(\.kind), [.keyword(keyword: "fy", pluginID: "translate")])
        XCTAssertEqual(library.items(of: .keyword).first?.title, "Translate")
        XCTAssertEqual(library.items(of: .app).map(\.title), ["Safari", "Notes"])
        XCTAssertEqual(library.items(of: .shortcut).map(\.kind), [.shortcut(name: "Pomodoro"),
                                                                  .shortcut(name: "Daily Brief")])
        XCTAssertEqual(library.items(of: .keys).count, RingKeyPreset.common.count)
        XCTAssertTrue(library.items(of: .url).isEmpty, "web pages are typed")
        XCTAssertEqual(library.items(of: .folder).map(\.kind), RingActionLibrary.defaultFolders.map {
            .folder(path: $0)
        })
    }

    func testEveryTypeHasACardAndOnlyTargetsShowASecondLine() {
        XCTAssertEqual(Set(RingActionLibrary.types), Set(RingActionType.allCases), "every type has a card")
        for type in RingActionLibrary.types {
            for item in library.items(of: type) {
                XCTAssertEqual(item.subtitleIdentifiesTarget, [.keyword, .keys, .folder].contains(type), item.title)
            }
        }
        XCTAssertTrue(RingActionLibrary.urlItem("github.com")?.subtitleIdentifiesTarget ?? false)
    }

    func testItemsCarryGroupsAndBuildActions() throws {
        let screenshot = try XCTUnwrap(library.items(of: .feature).first { $0.kind == .feature(.screenshot) })
        XCTAssertEqual(screenshot.group, L("ring.library.group.screenshot"))
        XCTAssertEqual(screenshot.type, .feature)
        XCTAssertEqual(screenshot.id, RingActionKind.feature(.screenshot).pickerKey)
        let id = UUID()
        let action = screenshot.action(id: id)
        XCTAssertEqual(action, RingAction(id: id, kind: .feature(.screenshot), title: RingFeature.screenshot.title,
                                          symbol: RingFeature.screenshot.symbol))
        for feature in RingFeature.allCases {
            XCTAssertTrue(["input", "screenshot", "windows"].contains(feature.libraryGroup))
        }
        for system in RingSystemAction.allCases {
            XCTAssertTrue(["appearance", "desktop", "security"].contains(system.libraryGroup))
        }
    }

    func testFilteringATypeAndTypingWhatIsNotListed() {
        XCTAssertEqual(library.items(of: .app, matching: "saf").map(\.title), ["Safari"])
        XCTAssertEqual(library.items(of: .app, matching: "").count, 2)

        let shortcuts = library.items(of: .shortcut, matching: "Brief Me")
        XCTAssertEqual(shortcuts.last?.kind, .shortcut(name: "Brief Me"), "an unlisted name can be typed")
        XCTAssertEqual(library.items(of: .shortcut, matching: "Pomodoro").map(\.kind), [.shortcut(name: "Pomodoro")],
                       "an exact match is not offered twice")

        let folders = library.items(of: .folder, matching: "~/Projects")
        XCTAssertEqual(folders.first?.kind, .folder(path: "~/Projects"))
        XCTAssertEqual(folders.first?.title, "Projects")
        XCTAssertEqual(library.items(of: .folder, matching: "Down").map(\.kind), [.folder(path: "~/Downloads")])
    }

    // MARK: - Search

    func testSearchCoversEveryTypeAndGroupsByType() {
        XCTAssertTrue(library.search("  ").isEmpty)
        let safari = library.search("safari")
        XCTAssertEqual(safari.map(\.kind), [.app(bundleIdentifier: "com.apple.Safari", name: "Safari")])
        XCTAssertEqual(safari.first?.group, RingActionType.app.title)

        let pomodoro = library.search("pomo")
        XCTAssertEqual(pomodoro.map(\.kind), [.shortcut(name: "Pomodoro")])
        XCTAssertEqual(library.search("fy").first?.kind, .keyword(keyword: "fy", pluginID: "translate"))
        let feature = library.search(RingFeature.notes.title)
        XCTAssertTrue(feature.contains { $0.kind == .feature(.notes) })
    }

    func testSearchOffersTypedAddressesAndPathsFirst() {
        let url = library.search("github.com/mylxsw")
        XCTAssertEqual(url.first?.kind, .url("https://github.com/mylxsw"))
        XCTAssertEqual(url.first?.title, "github.com")
        XCTAssertEqual(library.search("http://www.example.com").first?.title, "example.com")
        XCTAssertNil(RingActionLibrary.urlItem("not a site"))
        XCTAssertNil(RingActionLibrary.urlItem("localhost"))
        XCTAssertNil(RingActionLibrary.urlItem("ftp://example.com"))

        let path = library.search("/tmp/reports")
        XCTAssertEqual(path.first?.kind, .folder(path: "/tmp/reports"))
        XCTAssertEqual(path.first?.title, "reports")
        XCTAssertFalse(path.contains { $0.type == .url }, "a path is not a web address")
        XCTAssertEqual(RingActionLibrary.folderItem("~").title, L("ring.library.home"))
    }

    func testRecommendationsSkipWhatIsOnTheRing() {
        let none = library.recommendations(excluding: [])
        XCTAssertEqual(none.map(\.kind), Array(RingActionLibrary.recommended.prefix(4)))
        let withChat = library.recommendations(excluding: [.feature(.chat)], limit: 2)
        XCTAssertEqual(withChat.map(\.kind), [.system(.darkMode), .feature(.screenshotTranslation)])
        let everything = RingActionLibrary.recommended.compactMap(RingActionLibrary.item(for:)).map { $0.action() }
        XCTAssertTrue(library.recommendations(excluding: everything).isEmpty)
        XCTAssertTrue(RingActionLibrary.contains(none[0], in: [none[0].action()]))
        XCTAssertFalse(RingActionLibrary.contains(none[0], in: []))
    }

    // MARK: - Defaults

    func testDefaultTitlesAndSymbols() {
        let binding = HotkeyBinding(keyCode: 13, modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue))
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .feature(.notes)), RingFeature.notes.title)
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .system(.mute)), RingSystemAction.mute.title)
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .keyword(keyword: "fy", pluginID: "p")), "fy")
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .keyword(keyword: "fy", pluginID: "p"),
                                                      keywordName: { _, _ in "Translate" }), "Translate")
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .app(bundleIdentifier: "a.b", name: "Mail")), "Mail")
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .keys(binding)),
                       L("ring.editor.keysTitle", HotkeyFormat.display(binding)))
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .shortcut(name: "Brief")), "Brief")
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .url("https://www.typeflux.app")), "typeflux.app")
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .url("nope")), "nope")
        XCTAssertEqual(RingActionLibrary.defaultTitle(for: .folder(path: "~/Downloads")), "Downloads")

        XCTAssertEqual(RingActionLibrary.defaultSymbol(for: .feature(.notes)), RingFeature.notes.symbol)
        XCTAssertEqual(RingActionLibrary.defaultSymbol(for: .system(.lockScreen)), RingSystemAction.lockScreen.symbol)
        XCTAssertEqual(RingActionLibrary.defaultSymbol(for: .shortcut(name: "x")), RingActionType.shortcut.symbol)
        XCTAssertEqual(RingActionLibrary.keysItem(binding).kind, .keys(binding))
    }

    func testKeyPresetsAreDistinct() {
        let presets = RingKeyPreset.common
        XCTAssertEqual(Set(presets.map(\.binding.signature)).count, presets.count)
        XCTAssertFalse(presets.contains { $0.title.isEmpty })
    }

    // MARK: - Shortcuts

    func testShortcutListParsing() {
        XCTAssertEqual(RingShortcutsDiscovery.parse("Pomodoro\n\n  Daily Brief \nPomodoro\r\nLast"),
                       ["Pomodoro", "Daily Brief", "Last"])
        XCTAssertTrue(RingShortcutsDiscovery.parse("").isEmpty)
    }

    func testShortcutLoadingNeverThrows() async {
        let names = await RingShortcutsDiscovery.load(timeout: 10)
        XCTAssertEqual(names, RingShortcutsDiscovery.parse(names.joined(separator: "\n")))
    }
}

final class RingStudioLayoutTests: XCTestCase {
    private let actions = [RingAction.feature(.dictation), .feature(.ask), .feature(.translate)]

    func testOverviewDrawsTheSlicesAsTheyAre() {
        let slots = RingStudioLayout.slots(actions: actions, state: .overview, preview: nil)
        XCTAssertEqual(slots.map(\.action), actions)
        XCTAssertTrue(slots.allSatisfy { $0.role == .action })
        XCTAssertNil(RingStudioLayout.selectedIndex(in: slots, state: .overview, drag: nil))
        XCTAssertEqual(RingStudioLayout.selectedIndex(in: slots, state: .edit(actions[1].id), drag: nil), 1)
    }

    func testInsertingOpensAGapThatPreviewsTheHoveredItem() {
        let state = RingInspectorState.library(.insert(index: 1))
        let gap = RingStudioLayout.slots(actions: actions, state: state, preview: nil)
        XCTAssertEqual(gap.count, 4)
        XCTAssertEqual(gap[1].role, .placeholder)
        XCTAssertEqual(gap[1].id, RingStudioSlot.placeholderID)
        XCTAssertEqual(RingStudioLayout.selectedIndex(in: gap, state: state, drag: nil), 1)

        let notes = RingActionLibrary.item(for: RingFeature.notes)
        let previewed = RingStudioLayout.slots(actions: actions, state: state, preview: notes)
        XCTAssertEqual(previewed[1].role, .preview)
        XCTAssertEqual(previewed[1].action.title, notes.title)
        XCTAssertEqual(previewed[1].action.kind, notes.kind)

        let past = RingStudioLayout.slots(actions: actions, state: .library(.insert(index: 99)), preview: nil)
        XCTAssertEqual(past.last?.role, .placeholder)
    }

    func testReplacingPreviewsInPlace() {
        let state = RingInspectorState.library(.replace(actions[2].id))
        let same = RingStudioLayout.slots(actions: actions, state: state, preview: nil)
        XCTAssertEqual(same.map(\.action), actions, "nothing changes before an item is hovered")
        let mute = RingActionLibrary.item(for: RingSystemAction.mute)
        let slots = RingStudioLayout.slots(actions: actions, state: state, preview: mute)
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[2].id, actions[2].id)
        XCTAssertEqual(slots[2].role, .preview)
        XCTAssertEqual(slots[2].action.symbol, mute.symbol)
        XCTAssertEqual(RingStudioLayout.selectedIndex(in: slots, state: state, drag: nil), 2)
    }

    func testDraggingReordersLive() {
        let drag = RingStudioLayout.Drag(id: actions[0].id, destination: 2)
        let slots = RingStudioLayout.slots(actions: actions, state: .overview, preview: nil, drag: drag)
        XCTAssertEqual(slots.map(\.id), [actions[1].id, actions[2].id, actions[0].id])
        XCTAssertEqual(RingStudioLayout.selectedIndex(in: slots, state: .overview, drag: drag), 2)
        let unknown = RingStudioLayout.Drag(id: UUID(), destination: 0)
        XCTAssertEqual(RingStudioLayout.slots(actions: actions, state: .overview, preview: nil, drag: unknown)
            .map(\.action), actions)
    }

    func testInsertionPointsSitBetweenNeighboursUntilFull() {
        XCTAssertEqual(RingStudioLayout.insertionIndexes(count: 0), [])
        XCTAssertEqual(RingStudioLayout.insertionIndexes(count: 1), [1])
        XCTAssertEqual(RingStudioLayout.insertionIndexes(count: 3), [1, 2, 3])
        XCTAssertEqual(RingStudioLayout.insertionIndexes(count: RingConfiguration.maxActions), [])
    }

    func testStateResolvesAgainstTheSlices() {
        let gone = UUID()
        XCTAssertEqual(RingInspectorState.overview.resolved(for: []), .library(.insert(index: 0)),
                       "an empty ring opens the library")
        XCTAssertEqual(RingInspectorState.edit(gone).resolved(for: actions), .overview)
        XCTAssertEqual(RingInspectorState.library(.replace(gone)).resolved(for: actions), .overview)
        XCTAssertEqual(RingInspectorState.edit(actions[0].id).resolved(for: actions), .edit(actions[0].id))
        XCTAssertEqual(RingInspectorState.library(.replace(actions[0].id)).resolved(for: actions),
                       .library(.replace(actions[0].id)))
        XCTAssertEqual(
            RingInspectorState.library(.insert(index: 9)).resolved(for: actions),
            .library(.insert(index: 3))
        )
        XCTAssertEqual(
            RingInspectorState.library(.insert(index: -1)).resolved(for: actions),
            .library(.insert(index: 0))
        )
        let full = (0 ..< RingConfiguration.maxActions).map { _ in RingAction.feature(.notes) }
        XCTAssertEqual(RingInspectorState.library(.insert(index: 1)).resolved(for: full), .overview,
                       "a full ring cannot take more")
        XCTAssertEqual(RingInspectorState.edit(actions[0].id).selectedID, actions[0].id)
        XCTAssertEqual(RingInspectorState.library(.replace(actions[1].id)).selectedID, actions[1].id)
        XCTAssertNil(RingInspectorState.library(.insert(index: 0)).selectedID)
        XCTAssertNil(RingInspectorState.overview.selectedID)
    }

    func testGeometryPlacesInsertionPointsAndFollowsDrags() {
        let geometry = RingPreviewGeometry(size: 400, count: 4)
        let gap = geometry.insertionPoint(for: 1)
        XCTAssertEqual(gap.x, 200 + geometry.outerRadius * cos(-.pi / 4), accuracy: 0.001)
        XCTAssertEqual(gap.y, 200 + geometry.outerRadius * sin(-.pi / 4), accuracy: 0.001)
        XCTAssertEqual(geometry.nearestIndex(to: CGPoint(x: 200, y: 10)), 0)
        XCTAssertEqual(geometry.nearestIndex(to: CGPoint(x: 390, y: 200)), 1)
        XCTAssertEqual(geometry.nearestIndex(to: CGPoint(x: 200, y: 399)), 2)
        XCTAssertEqual(geometry.nearestIndex(to: CGPoint(x: 0, y: 200)), 3)
        XCTAssertEqual(RingPreviewGeometry(size: 400, count: 0).nearestIndex(to: .zero), 0)
        let single = RingPreviewGeometry(size: 400, count: 1).insertionPoint(for: 1)
        XCTAssertEqual(single.y, 200 + RingPreviewGeometry(size: 400, count: 1).outerRadius, accuracy: 0.001,
                       "one slice leaves its gap at the bottom")
    }

    func testLibraryKeyboardHelpers() {
        XCTAssertNil(RingLibraryPanel.nextHighlight(after: nil, count: 0))
        XCTAssertEqual(RingLibraryPanel.nextHighlight(after: nil, count: 3), 0)
        XCTAssertEqual(RingLibraryPanel.nextHighlight(after: 1, count: 3), 2)
        XCTAssertEqual(RingLibraryPanel.nextHighlight(after: 2, count: 3), 0, "wraps to the first")

        let items = [RingActionLibrary.item(for: RingFeature.notes), RingActionLibrary.item(for: RingFeature.chat)]
        XCTAssertEqual(RingLibraryPanel.submission(items, highlighted: 1, query: ""), items[1])
        XCTAssertEqual(RingLibraryPanel.submission(items, highlighted: nil, query: "no"), items[0])
        XCTAssertNil(RingLibraryPanel.submission(items, highlighted: nil, query: " "),
                     "Return without a search or highlight does nothing")
        XCTAssertEqual(RingLibraryPanel.submission(items, highlighted: 7, query: "x"), items[0])
        XCTAssertNil(RingLibraryPanel.submission([], highlighted: nil, query: "x"))
    }

    func testKeyMapping() {
        func key(_ character: Character, option: Bool = false, left: Bool = false, right: Bool = false,
                 enter: Bool = false) -> RingStudioKey? {
            RingStudioKeyPresses.key(for: character, option: option, isLeft: left, isRight: right, isReturn: enter)
        }
        XCTAssertEqual(key("a", option: true, left: true), .movePrevious)
        XCTAssertEqual(key("a", option: true, right: true), .moveNext)
        XCTAssertNil(key("a", left: true), "plain arrows are move commands")
        XCTAssertEqual(key("\r", enter: true), .edit)
        XCTAssertEqual(key("+"), .insert)
        XCTAssertEqual(key("="), .insert)
        XCTAssertEqual(key("1"), .select(0))
        XCTAssertEqual(key("8"), .select(7))
        XCTAssertNil(key("9"))
        XCTAssertNil(key("0"))
        XCTAssertNil(key("x"))
    }
}
