import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
private struct LauncherInputSourceCatalog: AskLauncherInputSourceListing {
    var sources: [AskLauncherInputSource] = [
        .init(id: "test.abc", name: "ABC"),
        .init(id: "test.wechat", name: "微信输入法")
    ]

    func availableSources() -> [AskLauncherInputSource] {
        sources
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct LauncherInputSourceSettingsTests {
    @Test func `native picker lists enabled sources and persists selection`() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLocalization.shared.setLanguage(language)
            #expect(LauncherSettingsPane.basics.title == (language == .english ? "General" : "通用"))
            for light in [false, true] {
                try await withView(light: light,
                                   name: "general-\(language.rawValue)-\(light ? "light" : "dark")") { settings, button in
                    #expect(button.itemTitles == [L("launcher.inputSource.none"), "ABC", "微信输入法"])
                    #expect(button.indexOfSelectedItem == 0)
                    #expect(button.accessibilityLabel() == L("launcher.inputSource.title"))
                    try choose(2, in: button)
                    #expect(settings.askLauncherInputSourceID == "test.wechat")
                    #expect(SettingsStore(defaults: settings.defaults).askLauncherInputSourceID == "test.wechat")
                    try await Task.sleep(for: .milliseconds(50))
                    #expect(button.titleOfSelectedItem == "微信输入法")
                    try choose(0, in: button)
                    #expect(settings.askLauncherInputSourceID.isEmpty)
                }
            }
        }
    }

    @Test func `saved unavailable source remains visible and can be cleared`() async throws {
        try await withView(savedID: "test.removed") { settings, button in
            #expect(button.itemTitles.last == L("launcher.inputSource.unavailable"))
            #expect(button.indexOfSelectedItem == 3)
            #expect(settings.askLauncherInputSourceID == "test.removed")
            try choose(0, in: button)
            #expect(settings.askLauncherInputSourceID.isEmpty)
        }
    }

    @Test func `saved source is restored and empty catalog still offers none`() async throws {
        try await withView(savedID: "test.abc") { _, button in
            #expect(button.titleOfSelectedItem == "ABC")
        }
        try await withView(catalog: LauncherInputSourceCatalog(sources: [])) { settings, button in
            #expect(button.itemTitles == [L("launcher.inputSource.none")])
            #expect(settings.askLauncherInputSourceID.isEmpty)
        }
    }

    private func withView(savedID: String? = nil, catalog: LauncherInputSourceCatalog? = nil,
                          light: Bool = false, name: String? = nil,
                          check: (SettingsStore, NSPopUpButton) async throws -> Void) async throws {
        _ = NSApplication.shared
        let suite = "launcher-input-source-view-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        if let savedID {
            settings.askLauncherInputSourceID = savedID
        }
        let size = NSSize(width: 574, height: 680)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: LauncherSettingsView(settings: settings, inputSources: catalog ?? .init())
            .padding(24).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(StudioTheme.windowBackground))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        let button = try #require(descendants(hosting).compactMap { $0 as? NSPopUpButton }.first)
        #expect(hosting.bounds.contains(hosting.convert(button.bounds, from: button)))
        try await check(settings, button)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"], let name {
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    private func choose(_ index: Int, in button: NSPopUpButton) throws {
        let menu = try #require(button.menu)
        let item = try #require(menu.item(at: index))
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
