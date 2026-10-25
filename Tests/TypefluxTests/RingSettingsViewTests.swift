import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct RingSettingsViewTests {
    func render(_ view: some View, size: NSSize, name: String, light: Bool,
                inspect: (@MainActor (NSView) async throws -> Void)? = nil) async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(StudioTheme.windowBackground))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(180))
        hosting.layoutSubtreeIfNeeded()
        try await inspect?(hosting)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    func page(_ store: SettingsStore, tab: RingSettingsView.Tab = .general) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(L("ring.title")).font(.system(size: 22, weight: .semibold))
            }
            RingSettingsView(settingsStore: store, tab: tab)
        }
        .padding(28)
    }

    @Test
    func `settings page renders in both appearances, with and without actions`() async throws {
        let suiteName = "RingSettingsViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        for light in [true, false] {
            for tab in RingSettingsView.Tab.allCases {
                try await render(page(store, tab: tab),
                                 size: NSSize(width: 860, height: 760),
                                 name: "ring-settings-\(tab.rawValue)-\(light ? "light" : "dark")", light: light)
            }
        }
        store.setHotkey(nil, for: .ring)
        try await render(page(store), size: NSSize(width: 860, height: 760),
                         name: "ring-settings-no-hotkey", light: false)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        var configuration = store.ringConfiguration
        configuration.actions = []
        store.ringConfiguration = configuration
        try await render(page(store, tab: .actions),
                         size: NSSize(width: 860, height: 760), name: "ring-settings-empty", light: true)
    }

    @Test
    func `tabs separate general controls from actions and preserve configuration`() async throws {
        let suiteName = "RingSettingsTabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let original = store.ringConfiguration
        #expect(RingSettingsView.Tab.allCases == [.general, .actions])
        #expect(RingSettingsView.Tab.general.title == L("settings.general"))
        #expect(RingSettingsView.Tab.actions.title == L("ring.actions.title"))
        try await render(page(store), size: NSSize(width: 860, height: 760),
                         name: "ring-settings-tabs-return", light: false) { hosting in
            @MainActor func element(_ identifier: String) -> NSObject? {
                var seen = Set<ObjectIdentifier>()
                func walk(_ node: NSObject) -> NSObject? {
                    guard seen.insert(ObjectIdentifier(node)).inserted else { return nil }
                    if node.responds(to: NSSelectorFromString("accessibilityIdentifier")),
                       node.value(forKey: "accessibilityIdentifier") as? String == identifier { return node }
                    guard node.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
                    for child in node.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] {
                        if let found = walk(child) { return found }
                    }
                    return nil
                }
                return walk(hosting)
            }
            @MainActor func select(_ tab: String) async throws {
                let button = try #require(element("ring.tab." + tab))
                try SettingsBehaviorTestSupport.Element(object: button).press()
                try await Task.sleep(for: .milliseconds(180))
                hosting.layoutSubtreeIfNeeded()
            }
            #expect(element("ring.hotkey") != nil)
            #expect(element("ring.centerTitle") != nil)
            #expect(element("ring.scope.global") == nil)
            try await select("actions")
            #expect(element("ring.hotkey") == nil)
            #expect(element("ring.centerTitle") == nil)
            #expect(element("ring.scope.global") != nil)
            try await select("general")
            #expect(element("ring.hotkey") != nil)
            #expect(element("ring.centerTitle") != nil)
            #expect(element("ring.scope.global") == nil)
        }
        #expect(store.ringConfiguration == original)
    }

    @Test
    func `ring settings follow global appearance without a separate style override`() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        try await SettingsBehaviorTestSupport.withFixture { store in
            let observer = InterfaceStyleObserver(settings: store)
            let original = store.ringConfiguration
            try await SettingsBehaviorTestSupport.withWindow(
                RingSettingsView(settingsStore: store).interfaceStyle(following: observer), width: 860, height: 900
            ) { _, hosting in
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.elements(in: hosting).contains {
                        $0.value("accessibilityIdentifier") as? String == "ring.hotkey"
                    }
                }
                for style in InterfaceStyle.allCases {
                    store.interfaceStyle = style
                    hosting.layoutSubtreeIfNeeded()
                    let elements = SettingsBehaviorTestSupport.elements(in: hosting)
                    let ids = Set(elements.compactMap { $0.value("accessibilityIdentifier") as? String })
                    #expect(ids.contains("ring.hotkey"))
                    #expect(ids.contains("ring.centerTitle"))
                    #expect(!ids.contains { $0.hasPrefix("ring.style.") })
                    #expect(observer.style == style)
                    #expect(store.ringConfiguration == original)
                }
            }
        }
    }

    private var sample: [RingAction] {
        RingConfiguration.defaultActions()
    }

    private var library: RingActionLibrary {
        RingActionLibrary(keywords: [KeywordHotkeyOption(keyword: AskKeyword(keyword: "fy", pluginID: "translate"),
                                                         name: "Translate")],
                          apps: [RingLibraryApp(name: "Finder", bundleIdentifier: "com.apple.finder")],
                          shortcuts: ["Pomodoro"])
    }

    private func canvas(_ actions: [RingAction], state: RingInspectorState, preview: RingLibraryItem? = nil,
                        issues: Set<UUID> = [], trying: Bool = false) -> some View {
        let slots = RingStudioLayout.slots(actions: actions, state: state, preview: preview)
        let mode: RingStudioCanvas.Mode = switch state {
        case .overview: .overview
        case .edit: .editing
        case .library(.insert): .inserting
        case .library(.replace): .replacing
        }
        var insertion = RingStudioLayout.insertionIndexes(count: actions.count)
        if case .library(.insert) = state {
            insertion = []
        }
        return RingStudioCanvas(slots: slots,
                                selectedIndex: RingStudioLayout.selectedIndex(in: slots, state: state, drag: nil),
                                mode: mode, style: .frosted, center: RingStudioCenter(title: "Typeflux"),
                                actionCount: actions.count,
                                insertionIndexes: insertion, issues: issues, drag: .constant(nil),
                                isTrying: .constant(trying))
    }

    @Test
    func `studio canvas renders every state`() async throws {
        let actions = sample
        let size = NSSize(width: 400, height: 520)
        try await render(canvas(actions, state: .overview), size: size, name: "ring-canvas-overview", light: true)
        try await render(canvas(actions, state: .edit(actions[2].id), issues: [actions[4].id]), size: size,
                         name: "ring-canvas-edit", light: false)
        try await render(canvas(actions, state: .library(.insert(index: 3))), size: size, name: "ring-canvas-gap",
                         light: true)
        try await render(canvas(actions, state: .library(.insert(index: 3)),
                                preview: RingActionLibrary.item(for: RingSystemAction.darkMode)),
                         size: size, name: "ring-canvas-preview", light: true)
        try await render(canvas([], state: .library(.insert(index: 0))), size: size, name: "ring-canvas-empty",
                         light: true)
        let full = actions + [RingAction.feature(.notes), .feature(.chat)]
        try await render(canvas(full, state: .overview, trying: true), size: size, name: "ring-canvas-full-try",
                         light: false)
    }

    @Test
    func `library panel renders home, a type, search and typed targets`() async throws {
        let size = NSSize(width: 380, height: 520)
        let actions = sample
        try await render(RingLibraryPanel(target: .insert(index: 3), actions: actions, library: library,
                                          isLoadingApps: false, preview: .constant(nil)),
                         size: size, name: "ring-library-home", light: true)
        try await render(RingLibraryPanel(target: .replace(actions[0].id), actions: actions, library: library,
                                          isLoadingApps: true, preview: .constant(nil)),
                         size: size, name: "ring-library-replace", light: false)
        try await render(RingLibraryPanel(target: .insert(index: 0), actions: [], library: library,
                                          isLoadingApps: false, preview: .constant(nil)),
                         size: size, name: "ring-library-first", light: true)
        for type in RingActionLibrary.types {
            try await render(RingLibraryPanel(target: .insert(index: 1), actions: actions, library: library,
                                              isLoadingApps: type == .app, preview: .constant(nil), category: type,
                                              url: type == .url ? "github.com" : ""),
                             size: size, name: "ring-library-type-\(type.rawValue)", light: type != .keys)
        }
        try await render(RingLibraryPanel(target: .insert(index: 1), actions: actions, library: RingActionLibrary(),
                                          isLoadingApps: true, preview: .constant(nil), category: .app),
                         size: size, name: "ring-library-apps-loading", light: true)
        try await render(RingLibraryPanel(target: .insert(index: 1), actions: actions, library: library,
                                          isLoadingApps: false, preview: .constant(nil), category: .url,
                                          url: "not a url"),
                         size: size, name: "ring-library-url-invalid", light: true)
        try await render(RingLibraryPanel(target: .insert(index: 1), actions: actions, library: library,
                                          isLoadingApps: false, preview: .constant(nil), query: "s"),
                         size: size, name: "ring-library-search", light: true)
        try await render(RingLibraryPanel(target: .insert(index: 1), actions: actions, library: library,
                                          isLoadingApps: false, preview: .constant(nil), query: "zzzz"),
                         size: size, name: "ring-library-no-results", light: false)
        try await render(RingLibraryPanel(target: .insert(index: 1), actions: actions, library: library,
                                          isLoadingApps: false, preview: .constant(nil), category: .shortcut,
                                          query: "zzzz"),
                         size: size, name: "ring-library-shortcut-typed", light: true)
        try await render(RingLibraryPanel(target: .insert(index: 1), actions: actions, library: RingActionLibrary(),
                                          isLoadingApps: false, preview: .constant(nil), category: .keyword),
                         size: size, name: "ring-library-empty-type", light: true)
        let row = RingLibraryRow(item: RingActionLibrary.item(for: RingFeature.screenshot), query: "shot",
                                 isHighlighted: true, isAdded: true) {}
        try await render(row, size: NSSize(width: 360, height: 46), name: "ring-library-row", light: true)
        for type in RingActionLibrary.types {
            try await render(RingTypeCard(type: type) {},
                             size: NSSize(width: 170, height: 96), name: "ring-library-card-\(type.rawValue)",
                             light: type != .system)
        }
    }

    @Test
    func `inspector renders the overview and every editable target`() async throws {
        let size = NSSize(width: 380, height: 520)
        let actions = sample
        let detail: (RingAction) -> String = { RingSettingsPresentation.summary(of: $0) }
        try await render(RingInspectorOverview(actions: actions, issues: [actions[1].id: "Gone"], detail: detail),
                         size: size, name: "ring-overview", light: true)
        let full = actions + [RingAction.feature(.notes), .feature(.chat)]
        try await render(RingInspectorOverview(actions: full, issues: [:], detail: detail), size: size,
                         name: "ring-overview-full", light: false)
        let binding = HotkeyBinding(keyCode: 13, modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue))
        let targets: [(String, RingAction, String?)] = [
            ("feature", actions[0], nil),
            ("url", RingAction(kind: .url("typeflux"), title: "typeflux", symbol: "link"), L("ring.error.invalidURL")),
            ("folder", RingAction(kind: .folder(path: "~/Downloads"), title: "Downloads", symbol: "folder"), nil),
            ("shortcut", RingAction(kind: .shortcut(name: "Pomodoro"), title: "Focus", symbol: "timer"), nil),
            ("keys", RingAction(kind: .keys(binding), title: "Close", symbol: "keyboard"), nil),
            ("app", RingAction(kind: .app(bundleIdentifier: "com.apple.finder", name: "Finder"), title: "Finder",
                               symbol: "app"), nil)
        ]
        for (name, action, issue) in targets {
            try await render(RingActionInspector(action: action, index: 2, count: 6, issue: issue,
                                                 defaultTitle: RingActionLibrary.defaultTitle(for: action.kind),
                                                 targetSummary: RingSettingsPresentation.summary(of: action)),
                             size: size, name: "ring-inspector-\(name)", light: name != "keys")
        }
        try await render(RingDirectionDots(index: 1, count: 3), size: NSSize(width: 30, height: 30),
                         name: "ring-direction-dots", light: true)
    }

    @Test
    func `action grid renders sparse and full layouts with long names`() async throws {
        var actions = Array((sample + [RingAction.feature(.notes), .feature(.chat)]).prefix(8))
        actions[0].title = "翻译当前选中的文字并保留原始格式"
        for count in [0, 1, 3, 7, 8] {
            for light in [true, false] {
                try await render(
                    RingInspectorOverview(actions: Array(actions.prefix(count)), issues: [:],
                                          detail: { $0.title }),
                    size: NSSize(width: 320, height: 520),
                    name: "ring-grid-\(count)-\(light ? "light" : "dark")", light: light
                )
            }
        }
    }

    @Test
    func `the OpieMenu adapter shows, aims and closes the real ring`() {
        _ = NSApplication.shared
        let menu = OpieRingMenu()
        var selected: [String] = []
        menu.onSelect = { selected.append($0) }
        menu.configure(items: [], style: .classic, centerTitle: "", center: .plain)
        menu.show(at: CGPoint(x: 400, y: 400), takesKeyboardFocus: true)
        #expect(!menu.isVisible, "an empty ring never opens")
        menu.configure(items: [
            RingMenuItem(id: "a", label: "Notes", symbol: "note.text"),
            RingMenuItem(id: "b", label: "Finder", symbol: "app", bundleIdentifier: "com.apple.finder"),
            RingMenuItem(id: "c", label: "Gone", symbol: "app", bundleIdentifier: "com.example.not-installed")
        ], style: .liquidGlass, centerTitle: "Go", center: RingMenuCenter(appBundleIdentifier: "com.apple.finder",
                                                                          pageCount: 2, pageIndex: 0))
        menu.show(at: CGPoint(x: 400, y: 400), takesKeyboardFocus: false)
        #expect(menu.isVisible)
        #expect(!menu.hasKeyboardFocus)
        menu.focusKeyboard()
        #expect(menu.hasKeyboardFocus)
        // Where the test pointer is decides whether a slice is under it; either way the ring closes.
        _ = menu.activatePointedItem()
        #expect(selected.count <= 1)
        menu.dismiss()
        // The closing animation runs on the main run loop.
        let deadline = Date().addingTimeInterval(3)
        while menu.isVisible, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(!menu.isVisible)
    }

    @Test
    func `preview maps points to slices clockwise from the top`() {
        let geometry = RingPreviewGeometry(size: 300, count: 4)
        #expect(geometry.index(at: geometry.center) == nil)
        #expect(geometry.index(at: CGPoint(x: 150, y: 150 - geometry.outerRadius + 4)) == 0)
        #expect(geometry.index(at: CGPoint(x: 150 + geometry.outerRadius - 4, y: 150)) == 1)
        #expect(geometry.index(at: CGPoint(x: 150, y: 150 + geometry.outerRadius - 4)) == 2)
        #expect(geometry.index(at: CGPoint(x: 150 - geometry.outerRadius + 4, y: 150)) == 3)
        #expect(geometry.index(at: CGPoint(x: 0, y: 0)) == nil)
        #expect(RingPreviewGeometry(size: 300, count: 0).index(at: CGPoint(x: 150, y: 80)) == nil)
        let point = geometry.point(at: 10, angle: geometry.angle(of: 0))
        #expect(abs(point.x - 150) < 0.001 && abs(point.y - 140) < 0.001)
    }
}

/// Per-app scopes.
extension RingSettingsViewTests {
    @Test
    func `per-app scopes render: tabs with More, info bars, app centre and global preview`() async throws {
        let suiteName = "RingSettingsViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        let bundles = ["com.apple.Safari", "com.apple.dt.Xcode", "com.apple.finder", "com.apple.mail",
                       "com.apple.Notes", "com.apple.Terminal", "com.example.gone"]
        var configuration = store.ringConfiguration
        configuration.appProfiles = bundles.enumerated().map { index, bundle in
            RingAppProfile(bundleIdentifier: bundle, appName: bundle.components(separatedBy: ".").last ?? bundle,
                           isEnabled: index != 2,
                           actions: RingAppShortcutCatalog.items(for: bundle, appName: "").map { $0.action() })
        }
        store.ringConfiguration = configuration
        try await render(page(store), size: NSSize(width: 860, height: 900), name: "ring-settings-apps", light: true)

        let profiles = store.ringConfiguration.appProfiles
        for (width, light) in [(CGFloat(860), true), (CGFloat(560), false)] {
            try await render(RingScopeBar(profiles: profiles, globalCount: 6, scope: .app(profiles[5].id), apps: [],
                                          isLoadingApps: false),
                             size: NSSize(width: width, height: RingScopeBar.height),
                             name: "ring-scope-bar-\(Int(width))", light: light)
        }
        try await render(RingScopeBar(profiles: [], globalCount: 6, scope: .global, apps: [], isLoadingApps: true),
                         size: NSSize(width: 560, height: RingScopeBar.height), name: "ring-scope-bar-empty",
                         light: true)
        for (index, profile) in [nil, profiles[0], profiles[2], profiles[6]].enumerated() {
            try await render(RingScopeInfoBar(profile: profile, hasOtherProfiles: index == 0, canReset: true,
                                              canCopyGlobal: true),
                             size: NSSize(width: 560, height: 50), name: "ring-scope-info-\(index)",
                             light: index.isMultiple(of: 2))
        }
        try await render(RingHiddenAppsList(profiles: profiles) { _ in }, size: NSSize(width: 280, height: 400),
                         name: "ring-scope-more", light: true)
        try await render(RingAddAppPicker(apps: [RingLibraryApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
                                                 RingLibraryApp(name: "Notes", bundleIdentifier: "com.apple.Notes")],
                                          isLoading: false, configured: ["com.apple.Safari"],
                                          running: ["com.apple.Notes"], onPick: { _, _ in }, onChooseOther: {}),
                         size: NSSize(width: 320, height: 400), name: "ring-scope-add", light: false)
    }

    @Test
    func `studio canvas renders an app centre and the global preview`() async throws {
        let actions = RingAppShortcutCatalog.items(for: "com.apple.Safari", appName: "Safari").map { $0.action() }
        let slots = RingStudioLayout.slots(actions: actions, state: .overview, preview: nil)
        let centers = [RingStudioCenter(title: "Safari", appBundleIdentifier: "com.apple.Safari", pageCount: 2),
                       RingStudioCenter(title: "Typeflux", pageCount: 2, pageIndex: 1)]
        for (index, center) in centers.enumerated() {
            let previewing = index == 1
            try await render(RingStudioCanvas(slots: slots, selectedIndex: nil, mode: .overview, style: .liquidGlass,
                                              center: center, actionCount: actions.count, insertionIndexes: [],
                                              issues: [], drag: .constant(nil), isTrying: .constant(false),
                                              onCenter: {}, isPreviewingGlobal: previewing),
                             size: NSSize(width: 400, height: 520),
                             name: previewing ? "ring-canvas-global-preview" : "ring-canvas-app", light: true)
        }
    }
}
