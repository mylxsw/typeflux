import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
    @Test func `prefix return lists all keywords and arrows enter without running`() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix", selection: "Captured words")
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.press(Self.returnKey)
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.isEmpty == false }
            #expect(model.plugins.keyword?.pluginID == AskPrefixPlugin.id)
            #expect(model.plugins.output?.items.count == AskPluginRegistry.defaultKeywords.count)
            #expect(model.plugins.request?.text == "" && model.plugins.request?.selection == nil)
            try await launcher.press(Self.down)
            #expect(model.plugins.output?.selected?.title == "dict")
            try await launcher.press(Self.returnKey)
            #expect(model.plugins.keyword?.keyword == "dict")
            #expect(model.launcherDraft.text.isEmpty && model.plugins.phase == .waiting)
            #expect(model.plugins.request == nil && launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty)
            #expect(await launcher.fixture.localAPI.sends.isEmpty)
        }
    }

    @Test func `prefix filtering by typing and return keeps the query out of the target`() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix g")
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.isEmpty == false }
            #expect(model.plugins.output?.selected?.title == "g")
            launcher.editor.selectAll(nil)
            launcher.editor.insertText("gh", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.original == "gh" }
            #expect(model.plugins.output?.items.first?.title == "gh", "the exact keyword ranks ahead of alias substrings")
            try await launcher.press(Self.returnKey)
            #expect(model.plugins.keyword?.keyword == "gh" && model.launcherDraft.text.isEmpty)
            #expect(model.plugins.phase == .waiting && launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `prefix disabled row cannot be entered and empty search has no action`() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix off", prepare: { model in
                model.modelLibrary.settings.saveAskLauncherKeywords(AskPrefixPlugin.keywords + [
                    AskKeyword(keyword: "off", pluginID: AskWebSearchPlugin.id, enabled: false)
                ])
            })
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.first?.title == "off" }
            #expect(model.plugins.output?.selected == nil && model.plugins.output?.selectedItem == -1)
            try await launcher.press(Self.returnKey)
            #expect(model.plugins.keyword?.pluginID == AskPrefixPlugin.id && launcher.dismissed == 0)
            launcher.editor.selectAll(nil)
            launcher.editor.insertText("unknown", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.original == "unknown" }
            #expect(model.plugins.output?.items.isEmpty == true)
            try await launcher.press(Self.returnKey)
            #expect(model.plugins.keyword?.pluginID == AskPrefixPlugin.id && launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `prefix list click enters the chosen feature`() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix gh")
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.first?.title == "gh" }
            let content = try #require(launcher.window.contentView)
            launcher.window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(80))
            content.layoutSubtreeIfNeeded()
            if let path = ProcessInfo.processInfo.environment["TYPEFLUX_PREFIX_SNAPSHOT"] {
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: path))
            }
            // SwiftUI exposes accessibility selectors without adopting the protocol.
            var seen = Set<ObjectIdentifier>()
            func descendants(_ element: Any) -> [NSObject] {
                guard let object = element as? NSObject,
                      seen.insert(ObjectIdentifier(object)).inserted else { return [] }
                let children = object.responds(to: NSSelectorFromString("accessibilityChildren"))
                    ? object.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
                return [object] + children.flatMap(descendants)
            }
            let elements = descendants(launcher.window)
            let row = try #require(elements.first {
                $0.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                    && $0.value(forKey: "accessibilityIdentifier") as? String == "ask.plugin.item"
            })
            // Invoke the native button's press action with its Objective-C BOOL signature.
            let selector = NSSelectorFromString("accessibilityPerformPress")
            #expect(row.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let press = unsafeBitCast(row.method(for: selector), to: Press.self)
            #expect(press(row, selector))
            try await AskQuickSearchSessionTests.wait { model.plugins.keyword?.keyword == "gh" }
            #expect(model.launcherDraft.text.isEmpty && model.plugins.phase == .waiting)
            #expect(launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }
}
