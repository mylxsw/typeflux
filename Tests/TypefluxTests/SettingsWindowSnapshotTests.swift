import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Captures the production window, including the native toolbar and sidebar compositor.
@Suite("Settings window snapshots", .exclusiveUIState)
@MainActor
struct SettingsWindowSnapshotTests {
    @Test func `window matrix`() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_WINDOW_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            defer { NSApp.setActivationPolicy(previousPolicy) }
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let history = FileHistoryStore(baseDir: directory.appendingPathComponent("history"))
            for style in InterfaceStyle.allCases {
                for dark in [false, true] {
                    settings.interfaceStyle = style
                    settings.appearanceMode = dark ? .dark : .light
                    let controller = SettingsWindowController()
                    controller.modelLibrary = library
                    controller.show(settingsStore: settings, historyStore: history, initialSection: .vocabulary)
                    let window = try #require(controller.window)
                    let model = try #require(controller.viewModel)
                    defer { window.close() }
                    for (term, source) in [("Tahoe", VocabularySource.automatic), ("Typeflux", .manual),
                                            ("SwiftUI", .automatic), ("PGVector", .manual)] {
                        if !model.vocabularyEntries.contains(where: { $0.term == term }) {
                            model.addVocabularyTerm(term, source: source)
                        }
                    }
                    window.setFrameOrigin(NSPoint(x: 40, y: 40))
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    for size in [NSSize(width: 1100, height: 800), NSSize(width: 720, height: 500)] {
                        window.setContentSize(size)
                        try await Task.sleep(for: .milliseconds(900))
                        window.displayIfNeeded()
                        try capture(window, file: directory.appendingPathComponent(
                            "settings-\(Int(size.width))-\(style.rawValue)-\(dark ? "dark" : "light").png"
                        ))
                    }
                }
            }
        }
    }

    @Test func searchAndAccessibilityMatrix() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_WINDOW_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            defer { NSApp.setActivationPolicy(previousPolicy) }
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            for style in InterfaceStyle.allCases {
                for dark in [false, true] {
                    settings.interfaceStyle = style
                    settings.appearanceMode = dark ? .dark : .light
                    let controller = SettingsWindowController()
                    controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
                    controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory),
                                    initialSection: .vocabulary)
                    let window = try #require(controller.window)
                    let model = try #require(controller.viewModel)
                    defer { window.close() }
                    window.setContentSize(NSSize(width: 1100, height: 800))
                    window.setFrameOrigin(NSPoint(x: 40, y: 40))
                    model.addVocabularyTerm("SwiftUI")
                    model.addVocabularyTerm("Typeflux")
                    try await Task.sleep(for: .milliseconds(600))
                    try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
                    let item = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first)
                    try await SettingsBehaviorTestSupport.wait { item.searchField.currentEditor() != nil }
                    let editor = try #require(item.searchField.currentEditor() as? NSTextView)
                    editor.insertText("SwiftUI", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    item.searchField.validateEditing()
                    item.searchField.sendAction(item.searchField.action, to: item.searchField.target)
                    try await SettingsBehaviorTestSupport.wait { model.filteredVocabularyEntries.count == 1 }
                    try await Task.sleep(for: .milliseconds(300))
                    try capture(window, file: directory.appendingPathComponent(
                        "search-\(style.rawValue)-\(dark ? "dark" : "light").png"
                    ))
                    if style == .liquidGlass {
                        try await captureAccessibility(window, model: model, dark: dark, directory: directory)
                    }
                }
            }
        }
    }

    private func captureAccessibility(_ window: NSWindow, model: StudioViewModel, dark: Bool,
                                      directory: URL) async throws {
        for reduced in [true, false] {
            let view = StudioView(viewModel: model).environment(\.typefluxAccessibilityOptions,
                TypefluxAccessibilityOptions(reduceTransparency: reduced, increasedContrast: !reduced))
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            window.contentView = host
            window.appearance = NSAppearance(named: reduced ? (dark ? .darkAqua : .aqua)
                : (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua))
            try await Task.sleep(for: .milliseconds(600))
            try capture(window, file: directory.appendingPathComponent(
                "\(reduced ? "reduce-transparency" : "increase-contrast")-\(dark ? "dark" : "light").png"
            ))
        }
    }

    private func capture(_ window: NSWindow, file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        window.displayIfNeeded()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: file).count > 1000)
    }
}
