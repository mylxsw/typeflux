import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct SettingsSidebarChromeTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: InterfaceStyle.allCases)
    func `chat footer keeps login and settings reachable after dismissal`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            var logins = 0
            var settingsOpened = 0
            func footer(compact: Bool) -> some View {
                SidebarAccountFooter(auth: AuthState.shared, compact: compact, defaults: settings.defaults,
                                     onSignIn: { logins += 1 }, onOpenAccount: {},
                                     onOpenSettings: { settingsOpened += 1 }).environment(\.interfaceStyle, style)
            }
            try await UI.withWindow(footer(compact: false), width: 256, height: 280) { _, host in
                try await UI.wait { UI.contains("Typeflux Cloud", in: host) }
                // The card owns the only sign-in action; the settings identity only shows status.
                #expect(signInButtons(in: host) == 1)
                #expect(!identityIsButton(in: host))
                #expect(UI.contains(L("ask.local.identity.localMode"), in: host))
                for feature in AskCloudPromo.features {
                    #expect(UI.contains(L(feature.key), in: host))
                }
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(logins == 1)
                try UI.button(L("ask.cloudPromo.dismiss"), in: host).press()
                try await UI.wait { !UI.contains("Typeflux Cloud", in: host) }
                #expect(settings.defaults.double(forKey: AskCloudPromo.dismissedKey) > 0)
                // Closing the card leaves a footer pill as the one sign-in action.
                #expect(signInButtons(in: host) == 1)
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(logins == 2)
                try UI.button(L("sidebar.settingsAccessibility"), in: host).press()
                #expect(settingsOpened == 1)
            }
            // Both windows share this dismissal preference, including newly opened footers.
            try await UI.withWindow(footer(compact: true), width: 256, height: 56.5) { window, host in
                #expect(!UI.contains("Typeflux Cloud", in: host))
                #expect(UI.contains(L("ask.local.identity"), in: host))
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                for label in [L("ask.cloudPromo.signIn"), L("sidebar.settingsAccessibility")] {
                    let button = try UI.button(label, in: host)
                    #expect(button.frame.minX >= bounds.minX - 1 && button.frame.maxX <= bounds.maxX + 1)
                    #expect(button.frame.height >= 28)
                }
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(logins == 3)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `dismissal updates both open sidebar footers`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            var localModeOpened = 0
            let settingsFooter = SidebarAccountFooter(
                auth: AuthState.shared, compact: false, defaults: settings.defaults,
                onSignIn: {}, onOpenAccount: {}
            ).environment(\.interfaceStyle, style)
            let chatFooter = SidebarAccountFooter(
                auth: AuthState.shared, compact: false, defaults: settings.defaults,
                onSignIn: {}, onOpenAccount: {}, onOpenSettings: {}
            ) {
                AskSignedOutIdentity(detail: "Chat local mode") { localModeOpened += 1 }
            }.environment(\.interfaceStyle, style)
            try await UI.withWindow(settingsFooter, width: 256, height: 280) { _, settingsHost in
                try await UI.withWindow(chatFooter, width: 256, height: 280) { _, chatHost in
                    try await UI.wait {
                        UI.contains("Typeflux Cloud", in: settingsHost) && UI.contains("Typeflux Cloud", in: chatHost)
                    }
                    #expect(!UI.contains(L("sidebar.settingsAccessibility"), in: settingsHost))
                    #expect(UI.contains(L("sidebar.settingsAccessibility"), in: chatHost))
                    try UI.button(L("ask.cloudPromo.dismiss"), in: settingsHost).press()
                    try await UI.wait {
                        !UI.contains("Typeflux Cloud", in: settingsHost) && !UI.contains("Typeflux Cloud", in: chatHost)
                    }
                    try UI.button(L("ask.local.identity"), in: chatHost).press()
                    #expect(localModeOpened == 1)
                    #expect(signInButtons(in: settingsHost) == 1 && signInButtons(in: chatHost) == 1)
                    #expect(!UI.contains(L("sidebar.settingsAccessibility"), in: settingsHost))
                    #expect(UI.contains(L("sidebar.settingsAccessibility"), in: chatHost))
                }
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `shared footer owns login transitions and account identity`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil },
                                 loadStoredUserProfile: { nil }, clearStoredSession: {})
            var logins = 0
            let footer = SidebarAccountFooter(
                auth: auth, compact: false, defaults: settings.defaults,
                onSignIn: { logins += 1 }, onOpenAccount: {}
            ).environment(\.interfaceStyle, style)
            try await UI.withWindow(footer, width: 256, height: 280) { _, host in
                try await UI.wait { UI.contains("Typeflux Cloud", in: host) }
                #expect(!UI.contains(L("sidebar.settingsAccessibility"), in: host))
                auth.userProfile = UserProfile(id: "u", email: "demir@example.com", name: "Demir Von",
                                               status: 1, provider: "google", createdAt: "", updatedAt: "")
                auth.isLoggedIn = true
                try await UI.wait { UI.contains("Demir Von", in: host) && !UI.contains("Typeflux Cloud", in: host) }
                #expect(!UI.contains(L("ask.local.identity"), in: host))
                auth.userProfile = nil
                try await UI.wait { UI.contains(L("sidebar.appName"), in: host) }
                #expect(signInButtons(in: host) == 0)
                #expect(!UI.contains(L("sidebar.settingsAccessibility"), in: host))
                auth.isLoggedIn = false
                try await UI.wait { UI.contains("Typeflux Cloud", in: host) && UI.contains(L("ask.local.identity"), in: host) }
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(logins == 1)
                #expect(settings.defaults.double(forKey: AskCloudPromo.dismissedKey) == 0)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases, [1100.0, 720.0])
    func `settings follows launcher in inline and compact navigation`(style: InterfaceStyle, width: Double) async throws {
        try await UI.withFixture { settings in
            var selected: StudioSection?
            let shell = StudioShell(
                currentSection: .launcher, onSelect: { selected = $0 }, onAccountAction: {},
                searchText: .constant(""), searchPlaceholder: "", accountDefaults: settings.defaults
            ) { _ in Text("Launcher content") }
                .environment(\.interfaceStyle, style)
            try await UI.withWindow(shell, width: width, height: 650) { window, host in
                #expect(!UI.contains(L("sidebar.settingsAccessibility"), in: host))
                let navigationHost: NSView
                if width < 1040 {
                    try UI.button(L("ask.sidebar.toggle"), in: host).press()
                    try await UI.wait { !(window.childWindows ?? []).isEmpty }
                    let popup = try #require(window.childWindows?.first)
                    navigationHost = try #require(popup.contentView)
                } else {
                    navigationHost = host
                }
                try await UI.wait { UI.contains(L("studio.section.settings"), in: navigationHost) }
                #expect(!UI.contains(L("sidebar.settingsAccessibility"), in: navigationHost))
                let launcher = try UI.button(L("studio.section.launcher"), in: navigationHost)
                let settingsButton = try UI.button(L("studio.section.settings"), in: navigationHost)
                #expect(settingsButton.frame.maxY <= launcher.frame.minY)
                try settingsButton.press()
                #expect(selected == .settings)
                try UI.snapshot(navigationHost, name: "settings-navigation-\(style.rawValue)-\(Int(width))")
                if width < 1040 {
                    try UI.button(L("ask.sidebar.toggle"), in: host).press()
                    try await UI.wait { (window.childWindows ?? []).isEmpty }
                }
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
                #expect(!UI.contains(
                    "语音听写历史只保存在这台 Mac 上。自动清理会移除过期本地记录和关联音频文件。", in: host
                ))
                #expect(UI.contains(L("home.transcriptionHistory"), in: host))
                #expect(!UI.elements(in: host).contains {
                    $0.value("accessibilityIdentifier") as? String == "studio.voiceInput.tab.history"
                })
                #expect(!UI.contains(L("home.activity.title"), in: host))
                // The toolbar can appear before the asynchronous history rows are loaded.
                try await UI.wait {
                    UI.elements(in: host).contains {
                        $0.role == NSAccessibility.Role.button.rawValue && $0.label == L("common.expand")
                    }
                }
                try await Task.sleep(for: .milliseconds(180))
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                for label in [L("history.action.exportMarkdown"), L("common.clear"), L("common.expand")] {
                    let button = try UI.button(label, in: host)
                    #expect(button.frame.width >= 20)
                    #expect(button.frame.minX >= bounds.minX - 1 && button.frame.maxX <= bounds.maxX + 1)
                }
                if size.width >= 1040 {
                    let identity = try identity(in: host)
                    #expect(identity.frame.minY >= bounds.minY && identity.frame.maxX < bounds.minX + 264)
                    #expect(UI.contains("Typeflux Cloud", in: host))
                } else {
                    try UI.button(L("ask.sidebar.toggle"), in: host).press()
                    try await UI.wait { !(window.childWindows ?? []).isEmpty }
                    let popup = try #require(window.childWindows?.first)
                    let popupHost = try #require(popup.contentView)
                    try await UI.wait { UI.contains(L("ask.local.identity"), in: popupHost) }
                    let popupBounds = popup.convertToScreen(popupHost.convert(popupHost.bounds, to: nil))
                    let identity = try identity(in: popupHost)
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

private extension SettingsSidebarChromeTests {
    func signInButtons(in host: NSView) -> Int {
        UI.elements(in: host).filter {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label == L("ask.cloudPromo.signIn")
        }.count
    }

    /// The settings identity is status, not a button, so find it by label alone.
    func identity(in host: NSView) throws -> SettingsBehaviorTestSupport.Element {
        try #require(UI.elements(in: host).first { $0.text == L("ask.local.identity") },
                     "Missing signed-out identity")
    }

    func identityIsButton(in host: NSView) -> Bool {
        UI.elements(in: host).contains {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label == L("ask.local.identity")
        }
    }
}
