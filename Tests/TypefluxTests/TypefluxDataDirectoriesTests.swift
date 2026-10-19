import Foundation
import Testing
@testable import Typeflux

@Suite("Typeflux data directories")
struct TypefluxDataDirectoriesTests {
    @Test func movesExistingFilesAndKeepsOldAbsolutePathsWorking() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/Typeflux")
        let workspaces = home.appendingPathComponent("Documents/Typeflux/Workspaces")
        let cache = home.appendingPathComponent("Library/Caches/Typeflux")
        for directory in [support, workspaces, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("existing".utf8).write(to: directory.appendingPathComponent("sentinel"))
        }

        let first = TypefluxDataDirectories.migrate(home: home, fileManager: .default)
        #expect(first.migrationErrors.isEmpty)
        #expect(first.data.path == home.appendingPathComponent(".typeflux/data").path)
        #expect(first.workspaces.path == home.appendingPathComponent(".typeflux/workspaces").path)
        #expect(first.cache.path == home.appendingPathComponent(".typeflux/cache").path)
        for (old, new) in [(support, first.data), (workspaces, first.workspaces), (cache, first.cache)] {
            #expect(try Data(contentsOf: new.appendingPathComponent("sentinel")) == Data("existing".utf8))
            #expect(try Data(contentsOf: old.appendingPathComponent("sentinel")) == Data("existing".utf8))
        }

        let second = TypefluxDataDirectories.migrate(home: home, fileManager: .default)
        #expect(second.migrationErrors.isEmpty)
        #expect(second.data == first.data)
    }

    @Test func leavesConflictingDirectoriesIntact() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appendingPathComponent("Library/Application Support/Typeflux", isDirectory: true)
        let new = home.appendingPathComponent(".typeflux/data", isDirectory: true)
        for directory in [old, new] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: old.appendingPathComponent("state"))
        try Data("new".utf8).write(to: new.appendingPathComponent("state"))

        let layout = TypefluxDataDirectories.migrate(home: home, fileManager: .default)
        #expect(layout.data == old)
        #expect(layout.migrationErrors.count == 1)
        #expect(try String(contentsOf: old.appendingPathComponent("state"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: new.appendingPathComponent("state"), encoding: .utf8) == "new")
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-migration-\(UUID().uuidString)")
    }
}
