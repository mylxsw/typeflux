import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct SettingsSidebarChromeTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: InterfaceStyle.allCases)
    func `shared footer keeps login reachable after dismissal`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            var logins = 0
            var settingsOpened = 0
            func footer(compact: Bool) -> some View {
                AskSidebarAccountFooter(signedIn: false, compact: compact, defaults: settings.defaults,
                                        onSignIn: { logins += 1 }, onOpenSettings: { settingsOpened += 1 }) {
                    AskSignedOutIdentity(detail: L("ask.local.identity.storage")) { logins += 1 }
                }.environment(\.interfaceStyle, style)
            }
            try await UI.withWindow(footer(compact: false), width: 256, height: 240) { _, host in
                try await UI.wait { UI.contains("Typeflux Cloud", in: host) }
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(logins == 1)
                try UI.button(L("ask.cloudPromo.dismiss"), in: host).press()
                try await UI.wait { !UI.contains("Typeflux Cloud", in: host) }
                #expect(settings.defaults.double(forKey: AskCloudPromo.dismissedKey) > 0)
                try UI.button(L("ask.local.identity"), in: host).press()
                #expect(logins == 2)
                try UI.button(L("sidebar.settingsAccessibility"), in: host).press()
                #expect(settingsOpened == 1)
            }
            // Both windows share this dismissal preference, including newly opened footers.
            try await UI.withWindow(footer(compact: true), width: 256, height: 56.5) { window, host in
                #expect(!UI.contains("Typeflux Cloud", in: host))
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                for label in [L("ask.local.identity"), L("sidebar.settingsAccessibility")] {
                    let button = try UI.button(label, in: host)
                    #expect(button.frame.minX >= bounds.minX - 1 && button.frame.maxX <= bounds.maxX + 1)
                    #expect(button.frame.height >= 28)
                }
                try UI.button(L("ask.local.identity"), in: host).press()
                #expect(logins == 3)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `native history keeps navigation and account inside every window`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            settings.interfaceStyle = style
            settings.appearanceMode = .dark
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let history = SQLiteHistoryStore(baseDir: directory)
            for index in 0 ..< 8 {
                history.save(record: HistoryRecord(date: .now.addingTimeInterval(Double(-index * 60)),
                                                   transcriptText: "请检查不同窗口尺寸下的历史记录，以及设置和聊天界面的账号区域是否保持一致。",
                                                   errorMessage: index == 2 ? "Unable to process this recording" : nil,
                                                   recordingStatus: .succeeded, transcriptionStatus: .succeeded,
                                                   processingStatus: index == 2 ? .failed : .succeeded,
                                                   applyStatus: .succeeded))
            }
            let controller = SettingsWindowController()
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            controller.show(settingsStore: settings, historyStore: history, initialSection: .history)
            let window = try #require(controller.window)
            defer { window.close() }
            #expect(window.toolbarStyle == .unified)
            #expect(window.toolbar != nil)
            for size in [NSSize(width: 1100, height: 800), NSSize(width: 1440, height: 900),
                         NSSize(width: 900, height: 620), NSSize(width: 720, height: 500)] {
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: 80, y: 80))
                let host = try #require(window.contentView)
                try await UI.wait { UI.contains(L("history.keep.title"), in: host) }
                try await Task.sleep(for: .milliseconds(180))
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                for label in [L("history.action.exportMarkdown"), L("common.clear"), L("common.expand")] {
                    let button = try UI.button(label, in: host)
                    #expect(button.frame.width >= 20)
                    #expect(button.frame.minX >= bounds.minX - 1 && button.frame.maxX <= bounds.maxX + 1)
                }
                if size.width >= 1040 {
                    let identity = try UI.button(L("ask.local.identity"), in: host)
                    #expect(identity.frame.minY >= bounds.minY && identity.frame.maxX < bounds.minX + 264)
                    #expect(UI.contains("Typeflux Cloud", in: host))
                } else {
                    try UI.button(L("ask.sidebar.toggle"), in: host).press()
                    try await UI.wait { !(window.childWindows ?? []).isEmpty }
                    let popup = try #require(window.childWindows?.first)
                    let popupHost = try #require(popup.contentView)
                    try await UI.wait { UI.contains(L("ask.local.identity"), in: popupHost) }
                    let popupBounds = popup.convertToScreen(popupHost.convert(popupHost.bounds, to: nil))
                    let identity = try UI.button(L("ask.local.identity"), in: popupHost)
                    #expect(identity.frame.minY >= popupBounds.minY - 1)
                    #expect(identity.frame.maxY <= popupBounds.maxY + 1)
                    try UI.button(L("ask.sidebar.toggle"), in: host).press()
                    try await UI.wait { (window.childWindows ?? []).isEmpty }
                }
                try await capture(window, name: "settings-history-\(style.rawValue)-\(Int(size.width))-dark")
            }
            window.close()
            settings.appearanceMode = .light
            let lightController = SettingsWindowController()
            lightController.modelLibrary = controller.modelLibrary
            lightController.show(settingsStore: settings, historyStore: history, initialSection: .history)
            let lightWindow = try #require(lightController.window)
            defer { lightWindow.close() }
            lightWindow.setContentSize(NSSize(width: 720, height: 500))
            lightWindow.setFrameOrigin(NSPoint(x: 80, y: 80))
            let lightHost = try #require(lightWindow.contentView)
            try await UI.wait { UI.contains(L("history.keep.title"), in: lightHost) }
            #expect(lightWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
            try await capture(lightWindow, name: "settings-history-\(style.rawValue)-720-light")
        }
    }

    private func capture(_ window: NSWindow, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: path).appendingPathComponent(name + ".png").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
