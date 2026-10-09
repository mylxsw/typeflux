import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in production-view snapshots and native AX evidence with synthetic data.
@Suite("Ask localization polish snapshots", .serialized)
@MainActor
struct AskLocalizationPolishVisualTests {
    @Test func renderPolishSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        let history = AskHistoryPlugin(conversations: { .empty })
        let request = AskPluginRequest(text: "", origin: .argument, keyword: AskHistoryPlugin.keywords[0],
                                       options: [:], interfaceLanguage: .simplifiedChinese)
        let plan = await history.plan(request)
        let output = try await history.run(request, plan: plan)
        let historyDisplay = AskPluginDisplay(hint: nil, title: history.title, symbol: history.symbol,
                                              phase: .done(plan, output), offersAskAI: false)
        let plugin = SignedOutPlugin()
        let session = AskPluginSession(plugins: [plugin], keywords: { plugin.defaultKeywords })
        session.enter(plugin.defaultKeywords[0])
        session.update(text: "Hello", selection: nil, language: .simplifiedChinese, runWhenPlanned: true)
        try await fixture.wait { if case .failed = session.phase { return true }; return false }
        let failureDisplay = AskPluginDisplay(hint: nil, title: L("ask.plugin.translate.title"), symbol: "translate",
                                              phase: session.phase, offersAskAI: false)
        let prefix = AskPrefixPlugin(entries: { fixture.model.launcherKeywordDirectory(language: $0) })
        var directoryDisplays: [(String, AskPluginDisplay)] = []
        for query in ["rw", "sum", "ex", "setting"] {
            var directoryRequest = request
            directoryRequest.keyword = AskPrefixPlugin.keywords[0]
            directoryRequest.text = query
            let directoryPlan = await prefix.plan(directoryRequest)
            let directoryOutput = try await prefix.run(directoryRequest, plan: directoryPlan)
            directoryDisplays.append(("directory-" + query, AskPluginDisplay(
                hint: nil, title: prefix.title, symbol: prefix.symbol,
                phase: .done(directoryPlan, directoryOutput), offersAskAI: false)))
        }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, display) in [("history", historyDisplay), ("sign-in", failureDisplay)] + directoryDisplays {
                try await render(VStack(spacing: 0) {
                    AskPluginResultsView(display: display, question: "", onMain: {}, onAction: { _ in },
                                         onAskAI: {}, onHighlight: { _ in })
                    Text(AskPluginResultsView.hint(for: display)).font(.system(size: 11)).padding(12)
                }.background(AskTheme.launcherSurface), size: NSSize(width: 680, height: 210),
                appearance: appearance, file: root.appendingPathComponent("\(name)-\(theme).png"))
            }
            let issue = AskSubmissionIssue(text: L("ask.local.modelRequired"), offersModels: true, offersSignIn: true)
            try await render(VStack(alignment: .leading, spacing: 16) {
                AskSubmissionIssueView(issue: issue, onModels: {}, onSignIn: {})
                HStack {
                    ForEach(AskPermissionMode.allCases, id: \.self) { mode in
                        AskPermissionModeMenu(mode: mode, compact: true, bare: true, onSelect: { _ in })
                    }
                    Spacer()
                }
                ForEach(AskPermissionMode.allCases, id: \.self) { mode in
                    Text(mode.title + " · " + mode.detail).font(.system(size: 12))
                }
                AskCloudPromoCard(onSignIn: {}, onDismiss: {})
            }.padding(16).background(AskTheme.launcherSurface), size: NSSize(width: 680, height: 360),
            appearance: appearance, file: root.appendingPathComponent("controls-\(theme).png"))
            try await render(AskUsagePanel(model: fixture.model, runId: .constant(nil), close: {})
                .environment(\.askGlassMaterialOverride, .opaque), size: NSSize(width: 360, height: 300),
                appearance: appearance, file: root.appendingPathComponent("usage-\(theme).png"))
            try await render(AskComposer(model: fixture.model, launcher: false).padding(16).background(AskTheme.launcherSurface),
                             size: NSSize(width: 760, height: 200), appearance: appearance,
                             file: root.appendingPathComponent("composer-\(theme).png"))
        }
        session.deactivate()
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top)
            .background(AskTheme.launcherSurface))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        var seen = Set<ObjectIdentifier>()
        func value(_ node: NSObject, _ key: String) -> Any? {
            node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
        }
        func nodes(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            return [node] + (value(node, "accessibilityChildren") as? [NSObject] ?? []).flatMap(nodes)
        }
        let tree = (nodes(window) + nodes(hosting)).map { node in
            ["accessibilityRole", "accessibilityIdentifier", "accessibilityLabel", "accessibilityValue", "accessibilityTitle"]
                .reduce(into: [String: String]()) { fields, key in
                    if let text = value(node, key) as? String { fields[key] = text }
                }
        }.filter { !$0.isEmpty }
        try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys])
            .write(to: file.deletingPathExtension().appendingPathExtension("ax.json"))
        #expect(png.count > 1000)
    }

    private struct SignedOutPlugin: AskLauncherPlugin {
        let id = "signed-out"
        let title = "Translation"
        let symbol = "translate"
        var defaultKeywords: [AskKeyword] { [.init(keyword: "fy", pluginID: id)] }
        func placeholder(selectionLines: Int?) -> String { "" }
        func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
        func plan(_ request: AskPluginRequest) async -> AskPluginPlan { .init(mode: .onSubmit, title: title) }
        func run(_ request: AskPluginRequest, plan: AskPluginPlan,
                 progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
            throw TypefluxCloudLLMError.notLoggedIn
        }
        func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
    }
}
