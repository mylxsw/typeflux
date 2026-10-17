import AppKit
import Testing
@testable import Typeflux

@Suite("Launcher typing motion", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherMotionTests {
    init() {
        let previous = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previous
    }

    private struct Element {
        let object: NSObject
        func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }

        var frame: NSRect {
            (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
        }
    }

    private func element(_ identifier: String, in window: NSWindow) throws -> Element {
        var seen = Set<ObjectIdentifier>()
        func find(_ node: Any) -> Element? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            let item = Element(object: object)
            if item.value("accessibilityIdentifier") as? String == identifier { return item }
            for child in item.value("accessibilityChildren") as? [Any] ?? [] {
                if let result = find(child) { return result }
            }
            return nil
        }
        return try #require(find(window), "Missing launcher control: \(identifier)")
    }

    private func editor(in view: NSView) -> AskComposerTextView.Editor? {
        (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(editor(in:)).first
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func controlsStayAttachedToTheirEdgesAsResultsChange(appearance: NSAppearance.Name) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        // Exercise changing result counts while the panel follows its content height.
        fixture.model.appIndex = AskTestAppIndex((0 ..< 2).map { AskTestAppIndex.app(
            "Alpha \($0)",
            id: "test.alpha\($0)"
        ) })
        fixture.model.fileIndex = AskTestFileIndex((0 ..< 1).map {
            ("/Users/test/Documents/Alpha/alpha \($0).txt", .file, Double($0))
        })
        fixture.model.launcherDraft.text = ""
        let suite = "ask-motion-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        // Open at the top of the usable area, on the screen `showLauncher` picks, so every
        // height grows down from a top edge with the most room below it.
        let screen = try #require(NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)
        let visible = screen.visibleFrame
        settings.askLauncherPosition = .lastPosition
        settings.askLauncherAnchors = [AskLauncherPlacement.key(for: screen): .init(
            left: AskLauncherPlacement.preferredFrame(on: visible).minX - visible.minX,
            fromTop: AskLauncherPlacement.screenMargin
        )]
        // This test measures typing motion; give its baseline the already captured context.
        await fixture.model.prepareLauncher()
        let controller = AskConversationWindowController(
            settings: settings,
            model: fixture.model,
            dockVisibility: DockVisibilityController(app: AskMotionActivationPolicy()),
            launcherInputSource: AskMotionInputSource()
        )
        defer { controller.dismissLauncher() }
        controller.showLauncher()
        let window = try #require(controller.launcherWindow)
        window.appearance = NSAppearance(named: appearance)
        let content = try #require(window.contentView)
        try await fixture.wait {
            fixture.model.launcherDraft.source == "Safari"
                && !fixture.model.capturing && !fixture.model.quickSearch.isSearching
        }
        try await Task.sleep(for: .milliseconds(250))
        try await fixture.wait { !controller.launcherIsResizing }
        #expect(window.frame.width == min(AskMetrics.launcherWidth, visible.width - 24))
        #expect(window.frame.height > 118, "The captured home must add space below the empty composer")
        let homeHeight = window.frame.height
        let editor = try #require(editor(in: content))
        let openChat = try element("ask.launcher.openChat", in: window)
        let screenshot = try element("ask.context.screenshot.toggle", in: window)
        let top = window.frame.maxY
        let headerInset = top - openChat.frame.midY
        let footerInset = screenshot.frame.midY - window.frame.minY
        var heights: [CGFloat] = []
        var index = 0
        let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_MOTION_SNAPSHOTS"]
        let mode = appearance == .aqua ? "light" : "dark"
        if let directory { try FileManager.default.createDirectory(
            atPath: directory + "/" + mode,
            withIntermediateDirectories: true
        ) }

        func sample() throws {
            content.layoutSubtreeIfNeeded()
            // The panel grows at once and shrinks after the card; the card's visible
            // bottom edge is what moves on each frame.
            let visible = controller.launcherVisibleHeight
            #expect(abs(window.frame.maxY - top) < 0.5, "the panel's top must remain anchored")
            #expect(window.frame.height >= visible - 0.5, "the card never draws outside its panel")
            #expect(abs((window.frame.maxY - openChat.frame.midY) - headerInset) < 0.5,
                    "open chat must stay in the header: \(openChat.frame.midY) in \(window.frame)")
            #expect(abs((screenshot.frame.midY - (window.frame.maxY - visible)) - footerInset) < 0.5,
                    "screenshot must follow the live footer: \(screenshot.frame.midY), card \(visible)")
            heights.append(visible)
            if let directory {
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory + "/" + mode + String(format: "/frame-%03d.png", index)))
            }
            index += 1
        }
        for text in ["a", "al", "alph", "alpha 1", "alph", "al", "a", "", "1+1", "hello world"] {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            for _ in 0 ..< 18 {
                try await Task.sleep(for: .milliseconds(12))
                try sample()
            }
            if text.isEmpty {
                #expect(abs(window.frame.height - homeHeight) < 1,
                        "Clearing input left height \(window.frame.height), expected \(homeHeight)")
            }
        }
        for _ in 0 ..< 55 {
            try await Task.sleep(for: .milliseconds(12))
            try sample()
        }
        #expect((heights.max() ?? 0) - (heights.min() ?? 0) < 1,
                "typing, deleting and new results must not resize the expanded launcher")
        #expect(abs(homeHeight - AskLauncherWindowMode.expandedHeight) < 1)
    }

    @Test func returnAndNumberShortcutsCannotRunTheDisplayedOldBatch() async throws {
        _ = NSApplication.shared
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let index = AskControlledSearchIndex()
        index.appSearch = { text in
            if text == "alph" { _ = gate.wait(timeout: .now() + 5) }
            return [.init(entry: AskTestAppIndex.app("Alpha"), score: 1)]
        }
        let fixture = try AskTestFixture()
        fixture.model.appIndex = index
        let controller = AskConversationWindowController(
            settings: fixture.model.modelLibrary.settings,
            model: fixture.model,
            dockVisibility: DockVisibilityController(app: AskMotionActivationPolicy()),
            launcherInputSource: AskMotionInputSource()
        )
        defer { controller.dismissLauncher(); fixture.model.resetSession() }
        controller.showLauncher()
        fixture.model.launcherDraft.text = "alpha"
        let window = try #require(controller.launcherWindow)
        let content = try #require(window.contentView)
        try await fixture.wait { !fixture.model.capturing && fixture.model.quickSearch.results?.apps.count == 1 }
        let editor = try #require(editor(in: content))
        editor.selectAll(nil)
        editor.insertText("alph", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.wait { fixture.model.quickSearch.pendingResults != nil }
        content.layoutSubtreeIfNeeded()
        #expect(editor.onCommandKey?(.enter) == true)
        #expect(editor.onCommandKey?(.number(1)) == true)
        #expect(window.isVisible, "an old app must not be opened and dismiss the launcher")
        #expect(await fixture.api.sends.isEmpty, "Return must not silently turn into Ask AI while searching")
        gate.signal()
        try await fixture
            .wait { fixture.model.quickSearch.pendingResults == nil && !fixture.model.quickSearch.isSearching }
    }
}

private final class AskMotionActivationPolicy: ActivationPolicyControlling {
    var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        currentActivationPolicy = policy
    }
}

@MainActor
private struct AskMotionInputSource: AskLauncherInputSourceSelecting {
    func select(sourceID: String) {}
}
