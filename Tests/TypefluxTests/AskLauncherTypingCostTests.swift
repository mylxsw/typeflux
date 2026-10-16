import Combine
import Foundation
import Testing
@testable import Typeflux

private final class TypingPermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func read() -> Bool {
        lock.withLock { reads += 1; return true }
    }

    var count: Int {
        lock.withLock { reads }
    }
}

/// Work the launcher must not repeat for every keystroke or pointer movement.
@Suite("Launcher typing cost", .exclusiveUIState)
@MainActor
struct AskLauncherTypingCostTests {
    @Test func `typing reuses keyword entries until the presentation or keywords change`() throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        let probe = TypingPermissionProbe()
        fixture.model.plugins.replacePlugins([AskScreenshotPlugin(isPermissionGranted: { probe.read() })])
        let first = fixture.model.typingLauncherSearchEntries(language: .english)
        let reads = probe.count
        #expect(reads > 0, "the first keystroke builds the entries")
        for _ in 0 ..< 20 {
            _ = fixture.model.typingLauncherSearchEntries(language: .english)
        }
        #expect(probe.count == reads, "later keystrokes must not read screen recording access again")
        #expect(fixture.model.typingLauncherSearchEntries(language: .english) == first)

        _ = fixture.model.typingLauncherSearchEntries(language: .simplifiedChinese)
        #expect(probe.count == reads, "one presentation reads access once, whatever the language")

        let beforePresentation = probe.count
        fixture.model.resetLauncherForPresentation()
        _ = fixture.model.typingLauncherSearchEntries(language: .simplifiedChinese)
        #expect(probe.count > beforePresentation, "each presentation reads access again")

        let beforeRegistry = probe.count
        fixture.model.plugins.replacePlugins([])
        let empty = fixture.model.typingLauncherSearchEntries(language: .simplifiedChinese)
        #expect(probe.count == beforeRegistry)
        #expect(!empty.contains { $0.keyword.pluginID == AskScreenshotPlugin.id },
                "a changed registry is not served stale")
    }

    @Test func `the open launcher's home reads access once per presentation`() throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        let probe = TypingPermissionProbe()
        fixture.model.plugins.replacePlugins([AskScreenshotPlugin(isPermissionGranted: { probe.read() })])
        _ = fixture.model.presentedLauncherHome()
        #expect(probe.count == 1)
        for _ in 0 ..< 10 {
            _ = fixture.model.presentedLauncherHome()
        }
        #expect(probe.count == 1, "clearing the input again must not repeat the TCC read")
        _ = fixture.model.launcherHomeContext()
        #expect(probe.count == 2, "a standalone snapshot still reads access itself")
        fixture.model.resetLauncherForPresentation()
        _ = fixture.model.presentedLauncherHome()
        #expect(probe.count == 3, "the next presentation reads access again")
    }

    @Test func `search state that does not change is not published again`() {
        let session = AskQuickSearchSession()
        var changes = 0
        let subscription = session.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        session.cancel()
        session.cancel()
        #expect(changes == 0, "cancelling an idle search changes nothing the launcher draws")
    }

    @Test func `list items resolve positions and headings in one pass`() throws {
        let entries = [AskLauncherSearchEntry(keyword: .init(keyword: "js", pluginID: "json"), title: "JSON Tools",
                                              detail: "", symbol: "curlybraces")]
        let results = try #require(AskQuickResults.search("json", sources: .init(entries: entries)))
        let items = AskQuickResultsView.listItems(for: results)
        #expect(items.map(\.row) == results.listRows)
        for item in items {
            #expect(results.rows[item.index] == item.row)
            #expect(item.id == results.identity(of: item.row))
            #expect(item.section
                == AskQuickResultsView.sectionStart(at: item.index, in: results.rows, results: results))
        }
        #expect(items.first?.section != nil, "the first row starts a section")
    }

    @Test func `a pointer records movement without a new value type`() {
        let pointer = AskSearchPointer(position: .zero)
        let alias = pointer
        #expect(pointer.moved(to: .init(x: 1, y: 1)))
        #expect(alias.position == .init(x: 1, y: 1), "views keep one shared pointer, not a copy per update")
        #expect(!alias.moved(to: .init(x: 1, y: 1)))
    }
}
