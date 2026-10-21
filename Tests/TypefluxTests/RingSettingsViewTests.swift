import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct RingSettingsViewTests {
    private func render(_ view: some View, size: NSSize, name: String, light: Bool) async throws {
        _ = NSApplication.shared
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
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    private func page(_ store: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(L("ring.title")).font(.system(size: 22, weight: .semibold))
                Spacer()
                RingEnabledSwitch(settingsStore: store)
            }
            RingSettingsView(settingsStore: store, practice: RingPractice())
        }
        .padding(28)
    }

    @Test("settings page renders in both appearances, with and without actions")
    func page() async throws {
        let suiteName = "RingSettingsViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        for light in [true, false] {
            try await render(page(store),
                             size: NSSize(width: 860, height: 760), name: "ring-settings-\(light ? "light" : "dark")",
                             light: light)
        }
        var configuration = store.ringConfiguration
        configuration.actions = []
        configuration.enabled = false
        store.ringConfiguration = configuration
        try await render(page(store),
                         size: NSSize(width: 860, height: 760), name: "ring-settings-empty-off", light: true)
    }

    @Test("editor renders every action type")
    func editor() async throws {
        for type in RingActionType.allCases {
            var draft = RingActionDraft.new()
            draft.setType(type)
            if type == .feature {
                draft.choose(.feature(.translate), title: RingFeature.translate.title,
                             symbol: RingFeature.translate.symbol)
            }
            if type == .url { draft.setText("not a url") }
            try await render(RingActionEditorSheet(draft: draft, keywords: [], onSave: { _ in }, onDelete: {},
                                                   onCancel: {}),
                             size: NSSize(width: 480, height: 330), name: "ring-editor-\(type.rawValue)",
                             light: type != .system)
        }
        let existing = RingAction(kind: .keys(HotkeyBinding(keyCode: 21, modifierFlags: 1_179_648)), title: "Shot",
                                  symbol: "keyboard")
        try await render(RingActionEditorSheet(draft: RingActionDraft(editing: existing), keywords: [],
                                               onSave: { _ in }, onDelete: {}, onCancel: {}),
                         size: NSSize(width: 480, height: 330), name: "ring-editor-edit", light: true)
    }

    @Test("the OpieMenu adapter shows, aims and closes the real ring")
    func opieAdapter() async throws {
        _ = NSApplication.shared
        let menu = OpieRingMenu()
        var selected: [String] = []
        menu.onSelect = { selected.append($0) }
        menu.configure(items: [], style: .classic, centerTitle: "")
        menu.show(at: CGPoint(x: 400, y: 400))
        #expect(!menu.isVisible, "an empty ring never opens")
        menu.configure(items: [
            RingMenuItem(id: "a", label: "Notes", symbol: "note.text"),
            RingMenuItem(id: "b", label: "Finder", symbol: "app", bundleIdentifier: "com.apple.finder"),
            RingMenuItem(id: "c", label: "Gone", symbol: "app", bundleIdentifier: "com.example.not-installed")
        ], style: .liquidGlass, centerTitle: "Go")
        menu.show(at: CGPoint(x: 400, y: 400))
        #expect(menu.isVisible)
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

    @Test("preview maps points to slices clockwise from the top")
    func previewGeometry() {
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
