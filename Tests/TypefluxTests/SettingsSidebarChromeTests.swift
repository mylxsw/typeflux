import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct SettingsSidebarChromeTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: InterfaceStyle.allCases)
    func `chat footer keeps a single login row and settings at every height`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            var logins = 0
            var settingsOpened = 0
            for compact in [false, true] {
                let footer = SidebarAccountFooter(auth: AuthState.shared, compact: compact, defaults: settings.defaults,
                                                  onSignIn: { logins += 1 }, onOpenAccount: {},
                                                  onOpenSettings: { settingsOpened += 1 })
                    .environment(\.interfaceStyle, style)
                try await UI.withWindow(footer, width: 220, height: 56) { window, host in
                    try await UI.wait { signInButtons(in: host) == 1 }
                    #expect(!UI.contains("Typeflux Cloud", in: host))
                    #expect(!UI.contains(L("ask.local.identity"), in: host))
                    let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                    for label in [L("ask.cloudPromo.signIn"), L("sidebar.settingsAccessibility")] {
                        let button = try UI.button(label, in: host)
                        #expect(bounds.contains(button.frame))
                        try button.press()
                    }
                }
            }
            #expect(logins == 2 && settingsOpened == 2)
            #expect(settings.defaults.double(forKey: AskCloudPromo.dismissedKey) == 0)
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `account only footers preserve historical promo dismissal preferences`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            let dismissedAt = Date().timeIntervalSince1970
            settings.defaults.set(dismissedAt, forKey: AskCloudPromo.dismissedKey)
            let footer = SidebarAccountFooter(auth: AuthState.shared, compact: false, defaults: settings.defaults,
                                              onSignIn: {}, onOpenAccount: {}, onOpenSettings: {})
                .environment(\.interfaceStyle, style)
            for _ in 0 ..< 2 {
                try await UI.withWindow(footer, width: 256, height: 56) { _, host in
                    try await UI.wait { signInButtons(in: host) == 1 }
                    #expect(!UI.contains("Typeflux Cloud", in: host))
                    #expect(!UI.contains(L("ask.cloudPromo.dismiss"), in: host))
                    #expect(settings.defaults.double(forKey: AskCloudPromo.dismissedKey) == dismissedAt)
                }
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `single account rows preserve chat local mode without duplicate status`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            var localModeOpened = 0
            let settingsFooter = StudioSidebarFooter(defaults: settings.defaults, compact: false) {}
                .environment(\.interfaceStyle, style)
            let chatFooter = SidebarAccountFooter(
                auth: AuthState.shared, compact: false, defaults: settings.defaults,
                onSignIn: {}, onOpenAccount: {}, onOpenSettings: {}
            ) {
                AskSignedOutIdentity(compact: true, detail: "Chat local mode") { localModeOpened += 1 }
            }.environment(\.interfaceStyle, style)
            try await UI.withWindow(settingsFooter, width: 220, height: 56) { _, settingsHost in
                try await UI.withWindow(chatFooter, width: 256, height: 56) { _, chatHost in
                    #expect(!UI.contains("Typeflux Cloud", in: settingsHost))
                    #expect(!UI.contains("Typeflux Cloud", in: chatHost))
                    #expect(!UI.contains(L("ask.local.identity"), in: settingsHost))
                    try UI.button(L("ask.local.identity"), in: chatHost).press()
                    #expect(localModeOpened == 1)
                    #expect(signInButtons(in: settingsHost) == 1 && signInButtons(in: chatHost) == 1)
                }
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `shared footer follows sign in transitions and account identity`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil },
                                 loadStoredUserProfile: { nil }, clearStoredSession: {})
            var logins = 0
            let footer = SidebarAccountFooter(
                auth: auth, compact: false, defaults: settings.defaults,
                onSignIn: { logins += 1 }, onOpenAccount: {}
            ).environment(\.interfaceStyle, style)
            try await UI.withWindow(footer, width: 256, height: 56) { _, host in
                try await UI.wait { signInButtons(in: host) == 1 }
                auth.userProfile = UserProfile(id: "u", email: "demir@example.com", name: "Demir Von",
                                               status: 1, provider: "google", createdAt: "", updatedAt: "")
                auth.isLoggedIn = true
                try await UI.wait { UI.contains("Demir Von", in: host) }
                #expect(signInButtons(in: host) == 0)
                auth.userProfile = nil
                try await UI.wait { UI.contains(L("sidebar.appName"), in: host) }
                auth.isLoggedIn = false
                try await UI.wait { signInButtons(in: host) == 1 }
                #expect(!UI.contains("Typeflux Cloud", in: host))
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(logins == 1)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases, [1100.0, 720.0])
    func `settings follows launcher in the native sidebar at both widths`(
        style: InterfaceStyle,
        width: Double
    ) async throws {
        try await UI.withFixture { settings in
            var selected: StudioSection?
            let shell = StudioShell(
                currentSection: .launcher, title: L("studio.section.launcher"), onSelect: { selected = $0 },
                onAccountAction: {},
                search: nil, searchPlaceholder: "", accountDefaults: settings.defaults
            ) { _ in Text("Launcher content") }
                .environment(\.interfaceStyle, style)
            try await UI.withWindow(shell, width: width, height: 650) { window, host in
                if width < 1040 { try TypefluxNavigationTestSupport.toggleSidebar(in: window) }
                #expect(!UI.contains(L("sidebar.settingsAccessibility"), in: host))
                let navigationHost = window
                try await UI.wait { UI.contains(L("studio.section.settings"), in: navigationHost) }
                #expect(!UI.contains(L("sidebar.settingsAccessibility"), in: navigationHost))
                let launcher = try UI.button(L("studio.section.launcher"), in: navigationHost)
                let settingsButton = try UI.button(L("studio.section.settings"), in: navigationHost)
                #expect(settingsButton.frame.maxY <= launcher.frame.minY)
                try settingsButton.press()
                #expect(selected == .settings)
                try UI.snapshot(host, name: "settings-navigation-\(style.rawValue)-\(Int(width))")
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
            defer { TypefluxNavigationTestSupport.closeWindow(window) }
            #expect(window.toolbarStyle == .unified)
            #expect(window.toolbar != nil)
            for size in [NSSize(width: 1100, height: 800), NSSize(width: 1440, height: 900),
                         NSSize(width: 900, height: 620), NSSize(width: 720, height: 500)] {
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: 80, y: 80))
                let host = try #require(window.contentView)
                try await UI.wait("History filter toolbar at width \(size.width)") {
                    AskWorkspaceTestAccessibility.frame(identifier: "history.filterMenu", in: window) != nil
                }
                // Native rows navigate to detail; the old in-row Expand control is gone.
                try await UI.wait("Loaded history navigation rows at width \(size.width)") {
                    UI.elements(in: host).contains {
                        ($0.value("accessibilityIdentifier") as? String)?.hasPrefix("history.open.") == true
                    }
                }
                try await Task.sleep(for: .milliseconds(180))
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                let identifiers = ["typeflux.toolbar.history.export", "typeflux.toolbar.history.clear"]
                try await UI.wait("History toolbar actions at width \(size.width)") {
                    identifiers.allSatisfy { AskWorkspaceTestAccessibility.frame(identifier: $0, in: window) != nil }
                }
                for identifier in identifiers {
                    let frame = try #require(AskWorkspaceTestAccessibility.frame(identifier: identifier, in: window))
                    #expect(frame.width >= 20)
                    #expect(frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1)
                }
                let row = try #require(UI.elements(in: host).first {
                    ($0.value("accessibilityIdentifier") as? String)?.hasPrefix("history.open.") == true
                        && !$0.frame.isEmpty
                })
                #expect(row.frame.minX >= bounds.minX - 1 && row.frame.maxX <= bounds.maxX + 1)
                if !UI.elements(in: window).contains(where: {
                    $0.label == L("ask.cloudPromo.signIn") && $0.frame.width > 0 && $0.frame.height > 0
                        && window.frame.contains($0.frame)
                }) {
                    try TypefluxNavigationTestSupport.toggleSidebar(in: window)
                }
                try await UI.wait {
                    UI.elements(in: window).contains {
                        $0.label == L("ask.cloudPromo.signIn") && $0.frame.height > 0 && window.frame.contains($0.frame)
                    }
                }
                let identity = try identity(in: window)
                #expect(identity.frame.minY >= bounds.minY && identity.frame.maxX < bounds.minX + 264)
                #expect(!UI.contains("Typeflux Cloud", in: window))
                try await capture(window, name: "settings-history-\(style.rawValue)-\(Int(size.width))-dark")
            }
            TypefluxNavigationTestSupport.closeWindow(window)
            settings.appearanceMode = .light
            let lightController = SettingsWindowController()
            lightController.modelLibrary = controller.modelLibrary
            lightController.show(settingsStore: settings, historyStore: history, initialSection: .history)
            let lightWindow = try #require(lightController.window)
            defer { TypefluxNavigationTestSupport.closeWindow(lightWindow) }
            lightWindow.setContentSize(NSSize(width: 720, height: 500))
            lightWindow.setFrameOrigin(NSPoint(x: 80, y: 80))
            let lightHost = try #require(lightWindow.contentView)
            try await UI.wait("Light History navigation rows") {
                UI.elements(in: lightHost).contains {
                    ($0.value("accessibilityIdentifier") as? String)?.hasPrefix("history.open.") == true
                }
            }
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

    /// The settings footer has one sign-in row.
    func identity(in host: Any) throws -> SettingsBehaviorTestSupport.Element {
        try #require(UI.elements(in: host).first { $0.label == L("ask.cloudPromo.signIn") && $0.role == NSAccessibility.Role.button.rawValue },
                     "Missing signed-out identity")
    }

}
