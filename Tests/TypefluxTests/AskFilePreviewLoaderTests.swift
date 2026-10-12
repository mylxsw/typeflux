import AppKit
import Testing
@testable import Typeflux

@Suite("File preview loader", .exclusiveUIState)
@MainActor
struct AskFilePreviewLoaderTests {
    let pixels = CGSize(width: 300, height: 200)
    func settle() async {
        for _ in 0 ..< 30 {
            await Task.yield()
        }
    }

    @Test func `cache invalidation eviction and memory pressure`() async {
        let clock = PreviewTestClock()
        var modified = Date(timeIntervalSince1970: 1), size: Int64 = 10, generated = 0
        let loader = AskFilePreviewLoader(metadata: { _, _ in .init(fileSize: size, modified: modified) },
                                          generate: { _, kind, _, _ in generated += 1; return .init(
                                              kind: kind,
                                              text: "1234567890"
                                          ) },
                                          clock: clock, countLimit: 2, costLimit: 20)
        var result: AskFilePreviewContent?
        loader.load(previewHit(), pixels: pixels) { result = $0 }; await settle()
        #expect(result?.fileSize == 10); #expect(generated == 1); #expect(loader.cacheCount == 1)
        loader.load(previewHit(), pixels: pixels) { result = $0 }; await settle()
        #expect(generated == 1)
        modified = modified.addingTimeInterval(1)
        loader.load(previewHit(), pixels: pixels) { result = $0 }; await settle()
        #expect(generated == 2); #expect(loader.cacheCount == 1)
        size = 11
        loader.load(previewHit(), pixels: pixels) { result = $0 }; await settle()
        #expect(generated == 3)
        loader.load(previewHit("2.txt"), pixels: pixels) { _ in }; await settle()
        loader.load(previewHit(), pixels: pixels) { _ in }; await settle()
        loader.load(previewHit("3.txt"), pixels: pixels) { _ in }; await settle()
        #expect(loader.cacheCount == 2); #expect(loader.cacheCost == 20)
        loader.load(previewHit("2.txt"), pixels: pixels) { _ in }; await settle()
        #expect(generated == 6)
        loader.clearCache(); #expect(loader.cacheCount == 0); #expect(loader.cacheCost == 0)
        loader.load(previewHit(), pixels: pixels) { _ in }; await settle()
        loader.setVisible(false); clock.advance(59); #expect(loader.cacheCount == 1)
        loader.setVisible(true); clock.advance(1); #expect(loader.cacheCount == 1)
        loader.setVisible(false); clock.advance(60); #expect(loader.cacheCount == 0)
    }

    @Test func `cancellation timeout failure and late completion`() async {
        let clock = PreviewTestClock()
        var waits: [CheckedContinuation<AskFilePreviewContent, any Error>] = []
        let loader = AskFilePreviewLoader(metadata: { _, _ in .init(fileSize: 1, modified: .distantPast) },
                                          generate: { _, _, _, _ in
                                              try await withCheckedThrowingContinuation { waits.append($0) }
                                          },
                                          clock: clock)
        var results: [AskFilePreviewContent?] = []
        loader.load(previewHit(), pixels: pixels) { results.append($0) }; await settle()
        loader.cancel(); waits.removeFirst().resume(returning: .init(kind: .text)); await settle()
        #expect(results.isEmpty); #expect(loader.cacheCount == 0)
        loader.load(previewHit(), pixels: pixels) { results.append($0) }; await settle()
        clock.advance(3); #expect(results.count == 1); #expect(results[0] == nil)
        waits.removeFirst().resume(returning: .init(kind: .text)); await settle()
        #expect(results.count == 1); #expect(loader.cacheCount == 0)
        loader.load(previewHit(), pixels: pixels) { results.append($0) }; await settle()
        waits.removeFirst().resume(throwing: AskFileReadError.timeout); await settle()
        #expect(results.count == 2); #expect(results[1] == nil)
    }

    @Test func `invalid metadata unsupported and oversize`() async {
        let clock = PreviewTestClock()
        var info = AskFileReadResponse(error: 13)
        var generated = 0, completed = false
        let loader = AskFilePreviewLoader(metadata: { _, _ in info }, generate: { _, kind, _, _ in
            generated += 1; return .init(kind: kind, text: "oversized")
        }, clock: clock, costLimit: 2)
        loader.load(previewHit(), pixels: pixels) { #expect($0 == nil); completed = true }; await settle()
        #expect(completed); #expect(generated == 0)
        info = .init(skippedMounts: ["/network"], fileSize: 1, modified: .distantPast)
        loader.load(previewHit(), pixels: pixels) { #expect($0 == nil) }; await settle()
        info = .init(fileSize: 1, modified: .distantPast)
        loader.load(previewHit("x.zip"), pixels: pixels) { #expect($0 == nil) }; await settle()
        #expect(generated == 0)
        loader.load(previewHit(), pixels: pixels) { #expect($0 != nil) }; await settle()
        #expect(generated == 1); #expect(loader.cacheCount == 0)
    }

    @Test func `only neighbour images and PD fs are prefetched`() async {
        var generated: [String] = []
        let loader = AskFilePreviewLoader(metadata: { _, _ in .init(fileSize: 1, modified: .distantPast) },
                                          generate: { hit, kind, _, _ in
                                              generated.append(hit.name); return .init(kind: kind)
                                          })
        loader.prefetch([previewHit("a.png"), previewHit("b.pdf"), previewHit("c.png")], pixels: pixels)
        await settle()
        #expect(Set(generated) == ["a.png", "b.pdf"])
        #expect(loader.cacheCount == 2)
        loader.prefetch([previewHit(), previewHit("c.mov")], pixels: pixels); await settle()
        #expect(generated.count == 2)
    }

    @Test func `memory pressure does not repopulate from inflight load`() async {
        var wait: CheckedContinuation<AskFilePreviewContent, any Error>?
        let loader = AskFilePreviewLoader(metadata: { _, _ in .init(fileSize: 1, modified: .distantPast) },
                                          generate: { _, _, _, _ in
                                              try await withCheckedThrowingContinuation { wait = $0 }
                                          })
        loader.load(previewHit(), pixels: pixels) { #expect($0 != nil) }; await settle()
        loader.clearCache(); wait?.resume(returning: .init(kind: .text, text: "ok")); await settle()
        #expect(loader.cacheCount == 0)
    }

    @Test func `preview setting defaults and persists`() throws {
        let name = "preview-setting-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askFilePreviewEnabled)
        settings.askFilePreviewEnabled = false
        #expect(!SettingsStore(defaults: defaults).askFilePreviewEnabled)
        settings.askFilePreviewEnabled = true
        #expect(settings.askFilePreviewEnabled)
    }
}
