import AppKit
import SwiftUI
import XCTest
@testable import Typeflux

/// Production views and native menus, run in a dedicated XCTest process with isolated settings.
@MainActor
final class ModelSettingsSnapshotTests: XCTestCase {
    func testScreenshots() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_MODEL_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            for style in InterfaceStyle.allCases {
                for dark in [false, true] {
                    settings.interfaceStyle = style
                    settings.appearanceMode = dark ? .dark : .light
                    let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                                                initialSection: .models, localModelManager: FixtureLocalModels(),
                                                modelLibrary: library)
                    let window = makeWindow(StudioView(viewModel: model), style: style, dark: dark)
                    defer { window.close() }
                    try await capturePages(window, model: model, root: root, style: style, dark: dark)
                    model.selectModelPageTab(.scenes)
                    try await Task.sleep(for: .milliseconds(500))
                    try capturePicker(window, root: root, style: style, dark: dark)
                    try await captureSheets(library: library, root: root, style: style, dark: dark)
                }
            }
        }
    }

    private func capturePages(_ window: NSWindow, model: StudioViewModel,
                              root: URL, style: InterfaceStyle, dark: Bool) async throws {
        let pages: [(String, ModelPageTab)] = [
            ("scenes", .scenes), ("providers", .providers), ("local", .local),
            ("provider", .providers), ("speech-provider", .providers), ("cloud", .providers)
        ]
        for (name, tab) in pages {
            model.selectModelPageTab(tab)
            if name == "provider" {
                model.selectedLanguageProviderID = "openAI"
            }
            if name == "cloud" {
                model.selectedLanguageProviderID = model.modelLibrary.providers.first(where: \.isCloud)?.id
            }
            if name == "speech-provider" {
                model.focusModelProvider(.whisperAPI)
                model.isShowingSpeechProviderDetail = true
            }
            try await Task.sleep(for: .milliseconds(500))
            try capture(
                window,
                file: root
                    .appendingPathComponent("\(name)-\(style.rawValue)-\(dark ? "dark" : "light").png")
            )
        }
    }

    private func capturePicker(_ window: NSWindow, root: URL,
                               style: InterfaceStyle, dark: Bool) throws {
        let button = try XCTUnwrap(window.contentView.flatMap {
            self.descendants($0).compactMap { $0 as? NSPopUpButton }.first
        })
        let file = root.appendingPathComponent("picker-\(style.rawValue)-\(dark ? "dark" : "light").png")
        let menu = try XCTUnwrap(button.menu)
        var failure: Error?
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated {
                do { try self.capture(window, file: file, includeMenu: true) } catch { failure = error }
                menu.cancelTrackingWithoutAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: button.selectedItem,
                   at: NSPoint(x: 0, y: button.bounds.midY), in: button)
        timer.invalidate()
        if let failure { throw failure }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func captureSheets(library: AskModelLibrary, root: URL, style: InterfaceStyle, dark: Bool) async throws {
        let models: [RegisteredModel] = [.init(id: "gpt-4.1", name: "GPT 4.1"),
                                         .init(id: "gpt-4.1-mini", name: "GPT 4.1 mini"), .init(
                                             id: "text-embedding-3-small",
                                             name: "Embedding"
                                         )]
        try await TypefluxUISnapshot.render(
            ModelCatalogView(providerName: "OpenAI", models: models,
                             existingIDs: ["gpt-4.1"], selected: .constant(["gpt-4.1", "gpt-4.1-mini"]),
                             onCancel: {}, onAdd: {}),
            size: NSSize(width: 620, height: 520), style: style, dark: dark,
            file: root.appendingPathComponent("catalog-\(style.rawValue)-\(dark ? "dark" : "light").png")
        )
        try await TypefluxUISnapshot.render(AddModelEndpointView(library: library),
                                            size: NSSize(width: 600, height: 520), style: style, dark: dark,
                                            file: root
                                                .appendingPathComponent(
                                                    "endpoint-\(style.rawValue)-\(dark ? "dark" : "light").png"
                                                ))
    }

    private func makeWindow(_ view: some View, style: InterfaceStyle, dark: Bool,
                            size: NSSize = NSSize(width: 1100, height: 800)) -> NSWindow {
        let window = NSPanel(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered,
                             defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "model-snapshot")
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.interfaceStyle, style)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = []
        window.contentView = host
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKey()
        return window
    }

    private func capture(_ window: NSWindow, file: URL, includeMenu: Bool = false) throws {
        window.displayIfNeeded()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if includeMenu, let screen = NSScreen.main {
            let rect = window.frame
            process.arguments = [
                "-x",
                "-R\(Int(rect.minX)),\(Int(screen.frame.maxY - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))",
                file.path
            ]
        } else {
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(try Data(contentsOf: file).count > 1000)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
