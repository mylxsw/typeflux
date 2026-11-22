import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask localization native accessibility", .serialized, .exclusiveUIState)
@MainActor
struct AskLocalizationPolishAccessibilityTests {
    init() {
        let previous = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previous
    }

    @Test func permissionModeSpeaksItsValueAndCloudIconIsDecorative() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        for mode in AskPermissionMode.allCases {
            try await withWindow(VStack {
                AskPermissionModeMenu(mode: mode, compact: true, bare: true, onSelect: { _ in })
                AskCloudPromoCard(onSignIn: {}, onDismiss: {})
            }, size: NSSize(width: 360, height: 200)) { window in
                let tree = nodes(window)
                let menu = try #require(tree.first { value($0, "accessibilityIdentifier") as? String == "ask.composer.permissionMode" })
                #expect(value(menu, "accessibilityValue") as? String == mode.title)
                #expect(value(menu, "accessibilityLabel") as? String == L("ask.mode.title") + ": " + mode.title)
                #expect(!text(tree).contains("Mostly Cloudy"))
                #expect(!text(tree).contains(mode.symbol))
                try record(tree, name: "permission-" + mode.rawValue)
            }
        }
    }

    @Test func composerButtonsHaveNamesAndPlaceholderTracksNewConversation() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "existing", title: "Existing", revision: 0, updatedAt: Date(), messages: []))
        await fixture.model.select("existing")
        fixture.model.draft = .followUp
        try await withWindow(AskComposer(model: fixture.model, launcher: false), size: NSSize(width: 760, height: 180)) { window in
            let field = try #require(editor(window.contentView!))
            #expect(field.accessibilityLabel() == L("ask.followup.placeholder"))
            fixture.model.newConversation()
            // The shared fixture starts work; a chat keeps the original question placeholder.
            try await fixture.wait { field.accessibilityLabel() == L("ask.input.placeholder.work") }
            fixture.model.setConversationKind(.chat, launcher: false)
            try await fixture.wait { field.accessibilityLabel() == L("ask.input.placeholder") }
            let tree = nodes(window)
            let attach = tree.filter { value($0, "accessibilityIdentifier") as? String == "ask.composer.attach" }
            #expect(attach.count == 1)
            #expect(value(try #require(attach.first), "accessibilityLabel") as? String == L("ask.attach.title"))
            let buttons = tree.filter { ["AXButton", "AXMenuButton", "AXPopUpButton"].contains(value($0, "accessibilityRole") as? String ?? "") }
            #expect(!buttons.isEmpty)
            for button in buttons {
                let name = ["accessibilityLabel", "accessibilityTitle"].compactMap { value(button, $0) as? String }
                    .joined().trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(!name.isEmpty, "Unnamed native button: \(value(button, "accessibilityIdentifier") ?? "no identifier")")
            }
            try record(tree, name: "composer")
        }
    }

    @Test func placeholderRowIsDisabledInTheNativeTree() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        try await withWindow(AskPluginItemRow(item: .init(id: "empty", title: "No history", valid: false),
            symbol: "clock", selected: true, emphasized: true, height: 44, onPick: {}), size: NSSize(width: 680, height: 44)) { window in
            let tree = nodes(window)
            let row = try #require(tree.first { value($0, "accessibilityIdentifier") as? String == "ask.plugin.item" })
            #expect(value(row, "isAccessibilityEnabled") as? Bool == false)
            try record(tree, name: "invalid-row")
        }
    }

    @Test func readPagesInReopenedNewsAnswerExpandAndOpenTheExactURL() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let urls = ["https://news.ycombinator.com/news", "https://www.bbc.com/news/world",
                    "https://www.bbc.com/sport/formula1", "https://www.theguardian.com/world",
                    "https://example.org/science"].map { URL(string: $0)! }
        let now = Date()
        let calls = urls.enumerated().map { index, url in
            AskToolCall(id: "fetch-\(index)", function: .init(name: "web_fetch", arguments: "{\"url\":\"\(url.absoluteString)\"}"))
        }
        let titles = ["Hacker News", "World news", "Formula 1", "World news | The Guardian", ""]
        var messages = [AskMessage(id: "q", role: "user", text: "今天有哪些值得关注的新闻？", createdAt: now),
                        AskMessage(id: "s", role: "assistant", text: "", toolCalls: calls, createdAt: now)]
        for (index, call) in calls.enumerated() {
            let title = titles[index].isEmpty ? "" : "Title: " + titles[index] + "\n"
            messages.append(.init(id: "r-\(index)", role: "tool", text: "URL: \(urls[index])\n" + title + "\nSample article",
                                  toolCallId: call.id, createdAt: now))
        }
        messages.append(.init(id: "a", role: "assistant", text: "国际新闻见 [BBC 世界新闻](https://www.bbc.com/news/world)，赛事动态见 [BBC 赛车](https://www.bbc.com/sport/formula1)。", createdAt: now))
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "news", title: "今日新闻", revision: 1, updatedAt: now, messages: messages))
        await fixture.model.select("news")
        var opened: URL?
        let view = AskConversationView(model: fixture.model)
            .environment(\.openURL, OpenURLAction { opened = $0; return .handled })
        try await withWindow(view, size: .init(width: 1060, height: 660)) { window in
            window.appearance = NSAppearance(named: .darkAqua)
            @MainActor func press(containing name: String) throws {
                let element = try #require(nodes(window).first { node in
                    ["AXButton", "AXLink"].contains(value(node, "accessibilityRole") as? String ?? "")
                        && text([node]).contains(name)
                }, "Missing control: \(name)")
                element.perform(NSSelectorFromString("accessibilityPerformPress"))
            }
            @MainActor func snapshot(_ name: String) throws {
                guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
                let content = try #require(window.contentView)
                content.layoutSubtreeIfNeeded()
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
            let label = L("ask.readPages.many", urls.count)
            #expect(!text(nodes(window)).contains(label))
            #expect(!text(nodes(window)).contains(L("ask.activity.results")))
            #expect(!text(nodes(window)).contains("Hacker News"))
            try press(containing: L("ask.activity.process"))
            try await Task.sleep(for: .milliseconds(150))
            try press(containing: label)
            try await Task.sleep(for: .milliseconds(200))
            let expanded = text(nodes(window))
            for url in urls { #expect(expanded.contains(String(url.absoluteString.dropFirst(8)))) }
            #expect(expanded.contains("Formula 1"))
            try snapshot("news-expanded")
            try press(containing: "www.bbc.com/sport/formula1")
            #expect(opened == urls[2])
            try press(containing: L("ask.activity.process"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(!text(nodes(window)).contains(label))
            #expect(!text(nodes(window)).contains("Hacker News"))
            try snapshot("news-collapsed")
        }
    }

    @Test func artifactFooterContainsOnlyDeliverables() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        var outputs = AskRunOutputs()
        let file = AskArtifactRef(id: "report", ownerId: "owner", conversationId: "c", runId: "r", version: "1",
                                  mediaType: "text/html", sizeBytes: 42, sha256: "", cleanup: "")
        outputs.storedArtifacts = [file]
        let outcome = AskTaskOutcome(id: "out", messageIDs: [], runIDs: [], changes: [])
        for count in [0, 8] {
            outputs.sources = (0..<count).map { URL(string: "https://example.org/story/\($0)")! }
            try await withWindow(AskTaskOutcomeView(outcome: outcome, outputs: outputs, active: false, actions: .init()),
                                 size: .init(width: 360, height: 500)) { window in
                let tree = nodes(window)
                #expect(text(tree).contains(L("ask.activity.results")))
                #expect(text(tree).contains(file.mediaType))
                let label = L("ask.readPages.many", count)
                #expect(!text(tree).contains(label))
            }
        }
    }

    private func withWindow<V: View>(_ view: V, size: NSSize, body: (NSWindow) async throws -> Void) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        try await body(window)
    }

    private func editor(_ view: NSView) -> AskComposerTextView.Editor? {
        (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(editor).first
    }

    private func value(_ node: NSObject, _ key: String) -> Any? {
        node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
    }

    private func nodes(_ window: NSWindow) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            return [node] + (value(node, "accessibilityChildren") as? [NSObject] ?? []).flatMap(visit)
        }
        return visit(window) + (window.contentView.map(visit) ?? [])
    }

    private func text(_ tree: [NSObject]) -> String {
        tree.flatMap { node in
            ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { value(node, $0) as? String }
        }.joined(separator: "\n")
    }

    private func record(_ tree: [NSObject], name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let output = tree.map { node in
            ["accessibilityRole", "accessibilityIdentifier", "accessibilityLabel", "accessibilityValue", "accessibilityTitle", "isAccessibilityEnabled"]
                .reduce(into: [String: String]()) { fields, key in
                    if let field = value(node, key) { fields[key] = String(describing: field) }
                }
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + "-asserted.ax.json"))
    }
}
