import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask localization native accessibility", .serialized)
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
