import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension FloatingPanelFidelityTests {
    @Test func clipboardWidthsMatchTheBoardAndKeepThePreviewAt280Points() {
        for (style, width): (InterfaceStyle, CGFloat) in [(.classic, 640), (.liquidGlass, 680)] {
            #expect(ClipboardPanelView.width(for: style) == width)
            #expect(ClipboardPanelView.size(showsPreview: false, style: style) == NSSize(width: width, height: 560))
            #expect(ClipboardPanelView.size(showsPreview: true, style: style) == NSSize(width: width + 280, height: 560))
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func clipboardPlaceholdersFitBothLanguagesAndAppearances(_ style: InterfaceStyle) async throws {
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppLocalization.shared.setLanguage(language)
            for dark in [false, true] {
                let model = ClipboardPanelModel()
                let view = ClipboardPanelView(model: model, focusRequest: 0)
                    .environment(\.interfaceStyle, style)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.glassMaterialOverride, .opaque)
                let size = ClipboardPanelView.size(showsPreview: false, style: style)
                try await TypefluxNavigationTestSupport.withWindow(view, size: size, nonactivating: true) { window, host in
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.appearance = window.appearance
                    let search = try #require(TypefluxNavigationTestSupport.searchField(in: host))
                    for category in [ClipboardCategory.all, .snippet] {
                        model.category = category
                        let prompt = L(category == .snippet ? "clipboard.snippet.search" : "clipboard.search.placeholder")
                        try await TypefluxNavigationTestSupport.wait("localized clipboard placeholder", in: window, host: host) {
                            search.placeholderString == prompt
                        }
                        host.layoutSubtreeIfNeeded()
                        let font = try #require(search.font)
                        #expect(font.pointSize == (style == .classic ? 20 : 21))
                        let cell = try #require(search.cell as? NSSearchFieldCell)
                        let textRect = cell.searchTextRect(forBounds: search.bounds)
                        let required = (prompt as NSString).size(withAttributes: [.font: font])
                        #expect(textRect.width >= ceil(required.width),
                                "\(language.rawValue) / \(style.rawValue) / \(dark): \(textRect.width) < \(required.width)")
                        #expect(window.frame.width == (style == .classic ? 640 : 680))
                        #expect(host.bounds.width == window.frame.width)
                    }
                }
            }
        }
    }

    @Test func switchingStyleDuringPreviewMotionKeepsWindowAndContentWidthsTogether() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.interfaceStyle = .liquidGlass
            let controller = ClipboardPanelController(settingsStore: settings)
            controller.reduceMotion = { false }
            let model = ClipboardPanelModel()
            controller.present(model)
            defer { controller.dismiss() }
            let window = try #require(controller.presentedWindow)
            model.showsPreview = true
            #expect(controller.isResizingPreview)
            settings.interfaceStyle = .classic
            #expect(!controller.isResizingPreview)
            #expect(window.frame.width == 920)
            #expect(controller.contentViewportWidth == 920)
            settings.interfaceStyle = .liquidGlass
            #expect(window.frame.width == 960)
            #expect(controller.contentViewportWidth == 960)
            controller.reduceMotion = { true }
            model.showsPreview = false
            #expect(window.frame.width == 680)
            #expect(controller.contentViewportWidth == 680)
            settings.interfaceStyle = .classic
            #expect(window.frame.width == 640)
            #expect(controller.contentViewportWidth == 640)
        }
    }
}
