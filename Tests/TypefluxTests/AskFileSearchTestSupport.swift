import Foundation
@testable import Typeflux

/// A file index over a fixed list of paths, searched with the real code.
final class AskTestFileIndex: AskFileSearching, @unchecked Sendable {
    var state: AskFileIndexState
    var status = AskFileIndexStatus(phase: .ready)
    var usage: [String: Int] = [:]
    private(set) var starts = 0
    private(set) var opened: [String] = []
    private(set) var forgotten: [String] = []
    private(set) var rebuilds = 0
    private(set) var clears = 0

    init(_ entries: [(path: String, kind: AskFileRecord.Kind, days: Double)] = [], home: String = "/Users/test",
         now: Date = Date()) {
        state = Self.state(entries, home: home, now: now)
    }

    /// An index of `entries`; folders above them are added as needed under `/`.
    static func state(_ entries: [(path: String, kind: AskFileRecord.Kind, days: Double)], home: String = "/Users/test",
                      now: Date = Date()) -> AskFileIndexState {
        var state = AskFileIndexState(home: home)
        state.directory("/")
        func ensure(_ folder: String) -> UInt32 {
            if let existing = state.directoryIndex[folder] { return existing }
            let parent = ensure((folder as NSString).deletingLastPathComponent)
            let record = state.add(name: (folder as NSString).lastPathComponent, directory: parent, kind: .folder,
                                   modified: now.addingTimeInterval(-86400 * 400))
            return state.directory(folder, parent: parent, record: record)
        }
        for entry in entries {
            let folder = (entry.path as NSString).deletingLastPathComponent
            let parent = ensure(folder)
            if entry.kind == .folder, let existing = state.directoryIndex[entry.path] {
                let record = state.directories[Int(existing)].record
                if record != AskFileDirectory.none {
                    state.touch(record, modified: now.addingTimeInterval(-86400 * entry.days))
                }
                continue
            }
            let index = state.add(name: (entry.path as NSString).lastPathComponent, directory: parent, kind: entry.kind,
                                  modified: now.addingTimeInterval(-86400 * entry.days))
            if entry.kind == .folder { state.directory(entry.path, parent: parent, record: index) }
        }
        return state
    }

    func search(_ query: AskSearchQuery, options: AskFileSearchOptions) -> [AskFileHit] {
        var options = options
        options.usage = usage
        return state.search(query, options: options)
    }

    func recent(options: AskFileSearchOptions) -> [AskFileHit] { state.recent(options: options) }
    func start() { starts += 1 }
    func recordOpen(_ path: String) { opened.append(path); usage[path, default: 0] += 1 }
    func forget(_ path: String) { forgotten.append(path); state.remove(path) }
    func rebuild() { rebuilds += 1 }
    func clear() { clears += 1 }

    /// Files a person might keep, for ranking tests; a new index each time, so tests can change it.
    static var sample: AskTestFileIndex { AskTestFileIndex([
        ("/Users/test/Documents/合同/2026 年度采购合同.pdf", .file, 2),
        ("/Users/test/Documents/合同/合同台账.xlsx", .file, 3),
        ("/Users/test/Documents/合同", .folder, 1),
        ("/Users/test/Documents/Typeflux/设计/内容搜索方案.md", .file, 0),
        ("/Users/test/Documents/周报/周报-第40周.docx", .file, 4),
        ("/Users/test/Documents/周报/周报-第39周.docx", .file, 11),
        ("/Users/test/Documents/发票/invoice-2026-09.pdf", .file, 20),
        ("/Users/test/Downloads/invoice-2026-08.pdf", .file, 48),
        ("/Users/test/Desktop/截图 2026-10-06.png", .file, 1),
        ("/Users/test/Projects/typeflux/README.md", .file, 3),
        ("/Users/test/Projects/typeflux/Package.swift", .file, 6),
        ("/Users/test/Projects/typeflux/docs/usage.md", .file, 8),
        ("/Users/test/Projects/realtime-asr/README.md", .file, 5),
        ("/Users/test/Pictures/团建/IMG_2041.HEIC", .file, 60),
        ("/Users/test/Projects/Rounded Report.key", .package, 30)
    ]) }
}

/// Records what the file watcher was asked to do, and lets a test send changes.
final class AskTestFileWatcher: AskFileWatching {
    private(set) var paths: [String] = []
    private(set) var since: UInt64?
    private(set) var stopped = 0
    private var onChange: (([AskFileChange], UInt64) -> Void)?

    func start(paths: [String], since: UInt64?, onChange: @escaping ([AskFileChange], UInt64) -> Void) {
        self.paths = paths
        self.since = since
        self.onChange = onChange
    }

    func stop() { stopped += 1; onChange = nil }

    func send(_ changes: [AskFileChange], id: UInt64 = 1) { onChange?(changes, id) }
}
