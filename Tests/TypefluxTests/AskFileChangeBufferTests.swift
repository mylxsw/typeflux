import Foundation
import Testing
@testable import Typeflux

@Suite("File index event batching")
struct AskFileChangeBufferTests {
    private func scope(roots: [String] = ["/home"]) -> AskFileScope {
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = roots
        settings.excludedPaths = ["/home/Library"]
        return AskFileScope(settings: settings, fullDiskAccess: true, home: "/home")
    }

    @Test func excludedHistoryProducesOneEmptyDrainAndAdvancesItsCursor() throws {
        let buffer = AskFileChangeBuffer(scope: scope())
        for event in 1 ... 1000 {
            let scheduled = buffer.append([
                .init(path: "/home/project/.build/\(event).o", rescan: false, isDirectory: false),
                .init(path: "/home/Library/cache/\(event)", rescan: false, isDirectory: false),
                .init(path: "/elsewhere/\(event)", rescan: false)
            ], lastEventID: UInt64(event))
            #expect(scheduled == (event == 1))
        }
        let batch = try #require(buffer.take())
        #expect(batch.changes.isEmpty && batch.lastEventID == 1000)
        #expect(buffer.take() == nil)
        #expect(buffer.append([], lastEventID: 900))
        #expect(buffer.take()?.lastEventID == 1000)
    }

    @Test func duplicatePathsRetainStructuralAndRescanInformation() throws {
        let buffer = AskFileChangeBuffer(scope: scope())
        #expect(buffer.append([.init(path: "/home/Docs/", rescan: false, isDirectory: true,
                                   structureChanged: true, renamed: true)], lastEventID: 1))
        #expect(!buffer.append([.init(path: "/home/Docs", rescan: false, isDirectory: nil)], lastEventID: 3))
        let batch = try #require(buffer.take())
        #expect(batch.changes == [.init(path: "/home/Docs", rescan: true, isDirectory: true,
                                      structureChanged: true, renamed: true)])
        #expect(batch.lastEventID == 3)
    }

    @Test func parentRescanAbsorbsDescendantsButKeepsIndependentExplicitRoots() throws {
        let buffer = AskFileChangeBuffer(scope: scope(roots: ["/home", "/home/Docs/Explicit"]))
        _ = buffer.append([
            .init(path: "/home/Docs/a.txt", rescan: false),
            .init(path: "/home/Docs", rescan: true, isDirectory: true),
            .init(path: "/home/Docs/Explicit/b.txt", rescan: false),
            .init(path: "/home/other.txt", rescan: false)
        ], lastEventID: 10)
        #expect(buffer.take()?.changes.map(\.path) == ["/home/Docs", "/home/Docs/Explicit/b.txt", "/home/other.txt"])
    }

    @Test func overflowKeepsBoundedRootRescansInsteadOfDroppingChanges() throws {
        let buffer = AskFileChangeBuffer(scope: scope(roots: ["/home", "/other"]), maximumPaths: 2)
        for index in 0 ..< 1000 {
            _ = buffer.append([.init(path: "/home/\(index)", rescan: false),
                               .init(path: "/other/\(index)", rescan: false)], lastEventID: UInt64(index))
        }
        #expect(buffer.take()?.changes == [.init(path: "/home", rescan: true, isDirectory: true),
                                           .init(path: "/other", rescan: true, isDirectory: true)])
        _ = buffer.append([.init(path: "/home/new.txt", rescan: false)], lastEventID: 1001)
        #expect(buffer.take()?.changes.map(\.path) == ["/home/new.txt"])
    }

    @Test func filesystemRootRescanIsNeverItsOwnDescendant() {
        let buffer = AskFileChangeBuffer(scope: scope(roots: ["/"]))
        _ = buffer.append([.init(path: "/", rescan: true, isDirectory: true),
                           .init(path: "/folder/a.txt", rescan: false)], lastEventID: 1)
        #expect(buffer.take()?.changes == [.init(path: "/", rescan: true, isDirectory: true)])
    }

    @Test func concurrentCallbacksKeepEveryDistinctPathAndTheNewestCursor() throws {
        let buffer = AskFileChangeBuffer(scope: scope())
        DispatchQueue.concurrentPerform(iterations: 100) { event in
            _ = buffer.append([.init(path: "/home/\(event).txt", rescan: false)], lastEventID: UInt64(event))
        }
        let batch = try #require(buffer.take())
        #expect(batch.changes.count == 100)
        #expect(batch.lastEventID == 99)
    }

    @Test func kindChangesCanRemovePreviouslyIndexedFilesOrFolders() {
        var scope = scope()
        scope.excludedExtensions = ["log"]
        let buffer = AskFileChangeBuffer(scope: scope)
        _ = buffer.append([
            .init(path: "/home/report.log", rescan: false, isDirectory: false),
            .init(path: "/home/node_modules", rescan: false, isDirectory: true),
            .init(path: "/home/node_modules/package/file.js", rescan: false, isDirectory: false)
        ], lastEventID: 1)
        #expect(buffer.take()?.changes.map(\.path) == ["/home/report.log", "/home/node_modules"])
    }
}
