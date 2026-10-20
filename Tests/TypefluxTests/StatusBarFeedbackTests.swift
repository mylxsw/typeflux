import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct StatusBarFeedbackTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: InterfaceStyle.allCases)
    func `sidebar header removes the support overflow button`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            for compact in [false, true] {
                let sidebar = StudioSidebar(
                    currentSection: .settings, onSelect: { _ in }, onAccountAction: {},
                    defaults: settings.defaults, compact: compact
                ).environment(\.interfaceStyle, style)
                try await UI.withWindow(sidebar, width: 256, height: compact ? 400 : 750) { _, host in
                    try await UI.wait { UI.contains(L("sidebar.appName"), in: host) }
                    #expect(!UI.contains(L("history.action.more"), in: host))
                    #expect(!UI.elements(in: host).contains {
                        $0.value("accessibilityIdentifier") as? String == "studio.supportMenu"
                    })
                }
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `menu feedback opens its own window and reopens it`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            settings.interfaceStyle = style
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let settingsWindow = SettingsWindowController.shared
            settingsWindow.window?.close()
            let feedback = FeedbackWindowController.shared
            feedback.window?.close()
            defer { feedback.window?.close() }
            let controller = StatusBarController(
                appState: AppStateStore(), settingsStore: settings,
                historyStore: FileHistoryStore(baseDir: directory)
            )
            controller.start()
            defer { controller.stop() }
            let menu = try #require(controller.menu)
            let updateIndex = try #require(menu.items.firstIndex { $0.title == L("menu.checkForUpdates") })
            #expect(menu.items[updateIndex + 1].title == L("menu.feedback"))
            let feedbackMenu = try #require(menu.items[updateIndex + 1].submenu)
            #expect(feedbackMenu.items.map(\.title) == FeedbackDestination.allCases.map(\.title))
            let guide = HelpWindowController.app(
                settings: settings, ask: nil, openSettings: { _ in },
                openFeedback: { controller.showFeedback($0) }
            )
            guide.show(query: "")
            defer { guide.dismiss() }
            // The first presentation, the already open window, and a window opened again after closing.
            for attempt in 0 ..< 3 {
                if attempt == 1 { guide.model.openFeedback(.direct) }
                else { feedbackMenu.performActionForItem(at: 0) }
                let window = try #require(feedback.window)
                try await UI.wait { window.isVisible }
                #expect(window.title == L("feedback.direct.title"))
                #expect(window.attachedSheet == nil)
                #expect(settingsWindow.window?.isVisible != true, "feedback must not open Settings")
                #expect(guide.isPresented && guide.model.isPresented)
                if attempt != 1 { window.performClose(nil) }
            }
        }
    }

    @Test func `menu and guide share external feedback destinations without closing the guide`() async throws {
        try await UI.withFixture { settings in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var urls: [URL] = []
            let controller = StatusBarController(
                appState: AppStateStore(), settingsStore: settings,
                historyStore: FileHistoryStore(baseDir: directory), onOpenFeedbackURL: { urls.append($0) }
            )
            controller.start()
            defer { controller.stop() }
            let menu = try #require(controller.menu?.items.first { $0.title == L("menu.feedback") }?.submenu)
            #expect(menu.items.compactMap { $0.representedObject as? String } == FeedbackDestination.allCases.map(\.rawValue))
            let guide = HelpWindowController.app(
                settings: settings, ask: nil, openSettings: { _ in },
                openFeedback: { controller.showFeedback($0) }
            )
            guide.show(query: "feedback")
            defer { guide.dismiss() }
            for destination in [FeedbackDestination.email, .github] {
                let index = try #require(menu.items.firstIndex { $0.representedObject as? String == destination.rawValue })
                menu.performActionForItem(at: index)
                guide.model.openFeedback(destination)
                let url = try #require(destination.url)
                #expect(urls.suffix(2) == [url, url])
                #expect(guide.isPresented && guide.model.query == "feedback")
            }
            let count = urls.count
            menu.items[1].representedObject = nil
            menu.performActionForItem(at: 1)
            menu.items[1].representedObject = "unknown"
            menu.performActionForItem(at: 1)
            #expect(urls.count == count && guide.isPresented)
        }
    }

    @Test func `feedback choices preserve the existing email and GitHub links`() throws {
        #expect(FeedbackDestination.direct.url == nil)
        #expect(FeedbackDestination.allCases.map(\.id) == ["direct", "email", "github"])
        #expect(FeedbackDestination.github.url?.absoluteString == "https://github.com/mylxsw/typeflux/issues/new")
        let email = try #require(FeedbackDestination.email.url)
        let components = try #require(URLComponents(url: email, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto" && components.path == "mylxsw@aicode.cc")
        #expect(components.queryItems == [
            URLQueryItem(name: "subject", value: "Typeflux Feedback"),
            URLQueryItem(name: "body", value: "Hi,\n\nI want to share some feedback about Typeflux:\n")
        ])
        for language in AppLanguage.allCases {
            #expect(FeedbackDestination.allCases.allSatisfy {
                AppLocalization.shared.string("sidebar.feedback.\($0.rawValue)Option", in: language)
                    != "sidebar.feedback.\($0.rawValue)Option"
            })
        }
    }
}
