import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Native renders of the inline semantic settings and result rows. Set
/// `TYPEFLUX_SEMANTIC_SCREENSHOTS` to a folder to keep the PNGs.
@Suite("Semantic settings visuals", .serialized, .exclusiveUIState)
@MainActor
struct SemanticFileSearchVisualTests {
    /// Renders `view` at its natural height so expanded inline controls remain visible.
    @discardableResult
    static func render(_ view: some View, width: CGFloat, name: String) async throws -> NSSize {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        var size = NSSize.zero
        for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(StudioTheme.background).environment(\.colorScheme, scheme))
            size = host.fittingSize
            window.setContentSize(size); window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCREENSHOTS"],
               let data = bitmap.representation(using: .png, properties: [:]) {
                let destination = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try data.write(to: destination.appendingPathComponent(
                    "\(name)-\(scheme == .light ? "light" : "dark").png"
                ))
            }
        }
        return size
    }

    @Test func `native settings card renders off ready and unsupported states`() async throws {
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let (unsupported, unsupportedRoot, _, _) = try SemanticFileServiceTests().fixture(supported: false)
        let (service, root, _, _) = try SemanticFileServiceTests().fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: unsupportedRoot)
        }
        func card(_ service: SemanticFileSearchService, filesEnabled: Bool = true) -> some View {
            SemanticFileSearchSettingsView(service: service, filesEnabled: filesEnabled).padding(24)
        }
        try await Self.render(card(unsupported), width: 760, name: "unsupported")
        let off = try await Self.render(card(service), width: 760, name: "card-off")
        #expect(service.setEnabled(true))
        await service.prepareModelIfNeeded()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let ready = try await Self.render(card(service), width: 760, name: "card-ready")
        #expect(ready.height > 100 && off.height > 100, "both inline states remain readable")
        try await Self.render(card(service, filesEnabled: false), width: 760, name: "card-files-off")
        await service.clear(removeModel: true)
    }

    @Test func `inline setup and management render without a sheet`() async throws {
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let (service, root, _, _) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = try await Self.render(SemanticFileSearchSettingsView(service: service, filesEnabled: true),
                                          width: 760, name: "inline-setup")
        #expect(setup.height > 100)
        #expect(service.setEnabled(true))
        await service.prepareModelIfNeeded()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let manage = try await Self.render(SemanticFileSearchSettingsView(service: service, filesEnabled: true),
                                           width: 760, name: "inline-manage")
        #expect(manage.height > 100)
        await service.clear(removeModel: true)
    }

    @Test func `content match rows render their passage`() async throws {
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let hit = AskFileHit(path: NSHomeDirectory() + "/Documents/项目资料/差旅与费用管理.pdf", name: "差旅与费用管理.pdf",
                             kind: .file, modified: Date(), score: 0.7,
                             evidence: .init(text: "出差结束后，请在 15 个工作日内提交报销申请，\n并附上交通、住宿发票及审批记录。", page: 6))
        let item = AskFileSearchPlugin.item(hit)
        let rows = VStack(spacing: AskPluginResultsView.itemSpacing) {
            AskPluginItemRow(item: item, symbol: "doc", selected: true, emphasized: true,
                             height: AskPluginResultsView.itemHeight(item), onPick: {})
            AskPluginItemRow(item: AskFileSearchPlugin.item(.init(path: "/tmp/2026 预算.xlsx", name: "2026 预算.xlsx",
                                                                  kind: .file, modified: Date(), score: 1)),
                             symbol: "doc", selected: false, emphasized: true,
                             height: AskPluginResultsView.itemHeight, onPick: {})
        }
        .padding(12)
        let size = try await Self.render(rows, width: 640, name: "launcher-content")
        #expect(size.height >= AskPluginResultsView.excerptItemHeight + AskPluginResultsView.itemHeight)

        // The mixed launcher list sizes each content match by its own height, highlighted or not.
        var name = hit
        name.evidence = nil; name.path = NSHomeDirectory() + "/Documents/报销流程.md"; name.name = "报销流程.md"
        var results = try #require(AskQuickResults.assemble("报销", matches: [], hits: [name, hit], status: nil,
                                                            settings: .init()))
        for highlighted in [false, true] {
            if highlighted, let row = results.rows.firstIndex(where: { results.file(at: $0)?.evidence != nil }) {
                results.highlighted = row
            }
            let list = AskQuickResultsView(results: results, question: "报销", onRun: { _, _ in }, onHighlight: { _ in })
            let mixed = try await Self.render(list, width: 680,
                                              name: highlighted ? "launcher-mixed-selected" : "launcher-mixed")
            #expect(mixed.height > 0)
        }
    }
}
