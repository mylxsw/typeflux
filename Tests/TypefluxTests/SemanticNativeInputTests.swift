import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Native semantic input to rendered results", .serialized, .exclusiveUIState)
@MainActor
struct SemanticNativeInputTests {
    func editor(in view: NSView) -> AskComposerTextView.Editor? {
        if let editor = view as? AskComposerTextView.Editor {
            return editor
        }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    @Test func `both entrypoints wait for IME commit render lexical and reject closed panel results`() async throws {
        _ = NSApplication.shared
        let accessibility = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(accessibility)
        NSApp.accessibilitySetValue(true, forAttribute: accessibility)
        defer { NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: accessibility) }
        let query = SemanticQueryProbe(delay: .milliseconds(500))
        let (service, root, _, _) = try await SemanticRealtimeSearchTests().fixture(query: query, text: "项目报销流程")
        defer { try? FileManager.default.removeItem(at: root) }
        let outputDirectory = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_UI_EVIDENCE"]
        for fileMode in [false, true] {
            let fixture = try AskTestFixture(authenticated: false)
            fixture.model.semanticSearch = service
            fixture.model.fileIndex = AskTestFileIndex()
            fixture.model.appIndex = AskTestAppIndex([])
            if fileMode {
                fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AskComposer(model: fixture.model, launcher: true).padding(20))
            host.sizingOptions = []
            window.contentView = host; window.orderFront(nil)
            defer {
                window.close(); fixture.model.resetSession()
                try? FileManager.default.removeItem(at: fixture.root)
            }
            try await SemanticFileServiceTests.ready { editor(in: host) != nil }
            let editor = try #require(editor(in: host))
            let before = query.calls
            editor.setMarkedText("baoxiao", selectedRange: NSRange(location: 7, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(80))
            #expect(editor.hasMarkedText() && fixture.model.launcherDraft.text.isEmpty)
            #expect(query.calls == before)
            editor.insertText("报销", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await SemanticFileServiceTests.ready {
                if fileMode {
                    return fixture.model.plugins.partial?.items.contains { $0.title == "handbook.txt" } == true
                }
                return fixture.model.quickSearch.results?.files.first?.name == "handbook.txt"
            }
            host.layoutSubtreeIfNeeded()
            if let outputDirectory {
                try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: outputDirectory)
                        .appendingPathComponent(fileMode ? "file-mode-ime.png" : "mixed-ime.png"))
            }
            try await SemanticFileServiceTests.ready {
                SettingsBehaviorTestSupport.elements(in: host).contains {
                    $0.text.contains("handbook.txt") || $0.label.contains("handbook.txt")
                }
            }
            editor.selectAll(nil); editor.deleteBackward(nil)
            try await SemanticFileServiceTests.ready { fixture.model.launcherDraft.text.isEmpty }
            fixture.model.quickSearch.setVisible(false)
            fixture.model.plugins.deactivate()
            window.close()
            try await Task.sleep(for: .milliseconds(550))
            #expect(fixture.model.quickSearch.results == nil && fixture.model.plugins.output == nil)
        }
        await service.clear(removeModel: true)
    }
}
