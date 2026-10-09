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
    func controlsStayAttachedToTheirEdgesAcrossEveryResize(appearance: NSAppearance.Name) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let fixture = try AskTestFixture()
        fixture.model.appIndex = AskTestAppIndex((0 ..< 8).map { AskTestAppIndex.app(
            "Alpha \($0)",
            id: "test.alpha\($0)"
        ) })
        fixture.model.fileIndex = AskTestFileIndex((0 ..< 10).map {
            ("/Users/test/Documents/Alpha/alpha \($0).txt", .file, Double($0))
        })
        fixture.model.launcherDraft.text = ""
        let suite = "ask-motion-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = AskConversationWindowController(
            settings: SettingsStore(defaults: defaults),
            model: fixture.model,
            dockVisibility: DockVisibilityController(app: AskMotionActivationPolicy()),
            launcherInputSource: AskMotionInputSource()
        )
        defer {
            controller.dismissLauncher()
            fixture.model.resetSession()
            defaults.removePersistentDomain(forName: suite)
        }
        controller.showLauncher()
        let window = try #require(controller.launcherWindow)
        window.appearance = NSAppearance(named: appearance)
        let content = try #require(window.contentView)
        try await fixture.wait { !fixture.model.capturing && !fixture.model.quickSearch.isSearching }
        try await Task.sleep(for: .milliseconds(700))
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
            #expect(abs(window.frame.maxY - top) < 0.5, "the panel's top must remain anchored")
            #expect(abs((window.frame.maxY - openChat.frame.midY) - headerInset) < 0.5,
                    "open chat must stay in the header during a resize")
            #expect(abs((screenshot.frame.midY - window.frame.minY) - footerInset) < 0.5,
                    "screenshot must follow the live footer, not the target height")
            heights.append(window.frame.height)
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
                        "Clearing input must close the empty result gap promptly")
            }
        }
        for _ in 0 ..< 55 {
            try await Task.sleep(for: .milliseconds(12))
            try sample()
        }
        #expect((heights.max() ?? 0) - (heights.min() ?? 0) > 100, "exercise real changes in result count")
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
        fixture.model.launcherDraft.text = "alpha"
        let controller = AskConversationWindowController(
            settings: fixture.model.modelLibrary.settings,
            model: fixture.model,
            dockVisibility: DockVisibilityController(app: AskMotionActivationPolicy()),
            launcherInputSource: AskMotionInputSource()
        )
        defer { controller.dismissLauncher(); fixture.model.resetSession() }
        controller.showLauncher()
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
    func selectEnglish() {}
}
