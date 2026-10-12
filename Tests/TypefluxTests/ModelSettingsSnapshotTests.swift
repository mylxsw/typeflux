import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Review artifacts use production views with isolated settings and no provider requests.
@Suite("Model settings screenshots", .serialized, .exclusiveUIState)
@MainActor
struct ModelSettingsSnapshotTests {
    @Test func screenshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_MODEL_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            for dark in [false, true] {
                settings.interfaceStyle = .classic
                settings.appearanceMode = dark ? .dark : .light
                let model = StudioViewModel(settingsStore: settings,
                                            historyStore: FileHistoryStore(baseDir: root
                                                .appendingPathComponent("history")),
                                            initialSection: .models, localModelManager: FixtureLocalModels(), modelLibrary: library)
                for name in [
                    "scenes",
                    "speech",
                    "language",
                    "provider",
                    "cloud",
                    "speech-provider",
                    "speech-google",
                    "speech-local",
                    "settings",
                    "hotkeys"
                ] {
                    model.navigate(to: name == "settings" || name == "hotkeys" ? .settings : .models)
                    model
                        .selectModelPageTab(name == "scenes" ? .scenes : name.hasPrefix("speech") ? .speech : .language)
                    if name == "provider" {
                        model.selectedLanguageProviderID = "openAI"
                    }
                    if name == "cloud" {
                        model.selectedLanguageProviderID = library.providers.first { $0.isCloud }?.id
                    }
                    if ["speech-provider", "speech-google", "speech-local"].contains(name) {
                        model.focusModelProvider(name == "speech-google" ? .googleCloud
                            : name == "speech-local" ? .localSTT : .whisperAPI)
                        model.isShowingSpeechProviderDetail = true
                    }
                    try await capture(
                        StudioView(viewModel: model, settingsPane: name == "hotkeys" ? .hotkeys : .appearance),
                        size: NSSize(width: 1100, height: 800),
                        style: .classic,
                        dark: dark,
                        file: root.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                    )
                }
            }
        }
    }

    private func capture(_ view: some View, size: NSSize, style: InterfaceStyle = .liquidGlass,
                         dark: Bool = false, backdrop: Color = .black, file: URL) async throws {
        let screen = try #require(NSScreen.main)
        let inset: CGFloat = 20
        let area = NSRect(x: screen.visibleFrame.minX + 4,
                          y: screen.visibleFrame.maxY - size.height - inset * 2 - 4,
                          width: size.width + inset * 2, height: size.height + inset * 2)
        let back = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        back.isReleasedWhenClosed = false
        back.level = .floating
        back.contentView = NSHostingView(rootView: backdrop.frame(width: area.width, height: area.height))
        let panel = NSPanel(contentRect: area.insetBy(dx: inset, dy: inset),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.interfaceStyle, style).environment(\.colorScheme, dark ? .dark : .light))
        back.orderFrontRegardless()
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil); panel.close()
            back.orderOut(nil); back.close()
        }
        try await Task.sleep(for: .milliseconds(900))
        panel.displayIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = [
            "-x",
            "-R\(Int(area.minX)),\(Int(screen.frame.maxY - area.maxY)),\(Int(area.width)),\(Int(area.height))",
            file.path
        ]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
