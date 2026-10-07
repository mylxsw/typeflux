import Foundation

/// One file or folder in the index. Plain values only, so the whole table can be
/// copied, scanned in parallel and written to disk as it is.
struct AskFileRecord: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
        case file = 0
        case folder = 1
        /// A bundle Finder shows as one file, such as an app or a Photos library.
        case package = 2
    }

    static let removedFlag: UInt8 = 1
    static let pinyinFlag: UInt8 = 2

    // Widest first, so the record packs into 40 bytes.
    var mask: UInt64
    /// The folded name in `keys`.
    var keyOffset: UInt32
    /// Word starts in `starts`.
    var startsOffset: UInt32
    /// The name as Finder shows it, in `names`.
    var nameOffset: UInt32
    var directory: UInt32
    /// Seconds since 2001, as `Date.timeIntervalSinceReferenceDate`.
    var modified: UInt32
    var keyLength: UInt16
    var nameLength: UInt16
    var startsCount: UInt8
    /// Where the extension's dot is in the folded name; 0 when there is none.
    var extensionStart: UInt8
    var kind: UInt8
    var flags: UInt8

    var isRemoved: Bool { flags & Self.removedFlag != 0 }
    var hasPinyin: Bool { flags & Self.pinyinFlag != 0 }
    var recordKind: Kind { Kind(rawValue: kind) ?? .file }
}

/// A folder that holds indexed entries: its path, and what its path adds to a search.
struct AskFileDirectory: Equatable, Sendable {
    var path: String
    var parent: UInt32
    /// The folder's own record in its parent; `none` for a search folder.
    var record: UInt32
    var depth: UInt16
    /// The folded path below the home folder, for words and `in:` that name a folder.
    var key: [UInt8]
    /// Every character of `key`.
    var mask: UInt64

    static let none = UInt32.max
}

/// A file found for the launcher's text.
struct AskFileHit: Equatable, Sendable, Identifiable {
    var path: String
    var name: String
    var kind: AskFileRecord.Kind
    var modified: Date
    /// The rank: the match with recency, use and depth.
    var score: Double
    /// How well the name itself matched (`AskFuzzyMatcher`'s tiers), for whether it may take Return.
    var match: Double = 0
    /// Characters of `name` that matched.
    var highlights: [Range<Int>] = []

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: kind == .folder) }
    var isFolder: Bool { kind == .folder }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// Everything the file index knows, as values: searching takes a copy, which costs
/// nothing until the indexer changes its own.
struct AskFileIndexState: Sendable {
    var records: [AskFileRecord] = []
    var keys: [UInt8] = []
    var starts: [UInt8] = []
    var names: [UInt8] = []
    var directories: [AskFileDirectory] = []
    /// `directories`' masks and depths on their own, for the search loop.
    var directoryMasks: [UInt64] = []
    var directoryDepths: [UInt16] = []
    /// Records in each directory, by directory index.
    var children: [[UInt32]] = []
    var directoryIndex: [String: UInt32] = [:]
    /// Pinyin for names with Chinese characters, by record.
    var pinyin: [UInt32: AskPinyinKey] = [:]
    var removed = 0
    var home: String

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    var count: Int { records.count - removed }

    // MARK: - Building

    /// The directory for `path`, adding it (and its record in its parent, when known) if new.
    @discardableResult
    mutating func directory(_ path: String, parent: UInt32 = AskFileDirectory.none,
                            record: UInt32 = AskFileDirectory.none) -> UInt32 {
        if let existing = directoryIndex[path] { return existing }
        let relative = AskLauncherSearchSettings.abbreviate(path, home: home)
        let key = AskSearchText.normalize(relative)
        let depth = parent == AskFileDirectory.none ? 0 : directories[Int(parent)].depth + 1
        let index = UInt32(directories.count)
        let mask = AskSearchText.mask(key)
        directories.append(AskFileDirectory(path: path, parent: parent, record: record, depth: depth, key: key,
                                            mask: mask))
        directoryMasks.append(mask)
        directoryDepths.append(depth)
        children.append([])
        directoryIndex[path] = index
        return index
    }

    /// Adds an entry named `name` in directory `directory`; its index.
    @discardableResult
    mutating func add(name: String, directory: UInt32, kind: AskFileRecord.Kind, modified: Date) -> UInt32 {
        // Packages such as Keynote decks have a type too.
        let key = AskSearchKey(name, hasExtension: kind != .folder)
        let nameBytes = Array(name.utf8)
        let keyLength = min(key.bytes.count, Int(UInt16.max))
        let startsCount = min(key.wordStarts.count, Int(UInt8.max))
        let record = AskFileRecord(
            mask: key.mask, keyOffset: UInt32(keys.count), startsOffset: UInt32(starts.count),
            nameOffset: UInt32(names.count), directory: directory, modified: Self.seconds(modified),
            keyLength: UInt16(keyLength), nameLength: UInt16(min(nameBytes.count, Int(UInt16.max))),
            startsCount: UInt8(startsCount),
            extensionStart: key.extensionStart.flatMap { $0 <= Int(UInt8.max) ? UInt8($0) : nil } ?? 0,
            kind: kind.rawValue, flags: key.pinyin == nil ? 0 : AskFileRecord.pinyinFlag)
        keys.append(contentsOf: key.bytes.prefix(keyLength))
        starts.append(contentsOf: key.wordStarts.prefix(startsCount))
        names.append(contentsOf: nameBytes.prefix(Int(record.nameLength)))
        let index = UInt32(records.count)
        records.append(record)
        children[Int(directory)].append(index)
        if let pinyin = key.pinyin { self.pinyin[index] = pinyin }
        return index
    }

    static func seconds(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(max(0, date.timeIntervalSinceReferenceDate)))
    }

    // MARK: - Reading

    func name(of record: AskFileRecord) -> String {
        let start = Int(record.nameOffset)
        return String(decoding: names[start ..< start + Int(record.nameLength)], as: UTF8.self)
    }

    func path(of index: UInt32) -> String {
        let record = records[Int(index)]
        let folder = directories[Int(record.directory)].path
        return (folder == "/" ? "" : folder) + "/" + name(of: record)
    }

    /// The record for `path`, if the index has it.
    func record(at path: String) -> UInt32? {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let directory = directoryIndex[folder] else { return nil }
        return children[Int(directory)].first { index in
            let record = records[Int(index)]
            return !record.isRemoved && self.name(of: record) == name
        }
    }

    // MARK: - Changing

    /// Marks `path` gone, with everything below it when it is a folder. True when anything changed.
    @discardableResult
    mutating func remove(_ path: String) -> Bool {
        var changed = false
        if let index = record(at: path) {
            records[Int(index)].flags |= AskFileRecord.removedFlag
            pinyin[index] = nil
            removed += 1
            changed = true
        }
        // Everything under the folder, found by path: its directory and those below it.
        let prefix = path + "/"
        let gone = directoryIndex.filter { $0.key == path || $0.key.hasPrefix(prefix) }
        for (folder, directory) in gone {
            for index in children[Int(directory)] where !records[Int(index)].isRemoved {
                records[Int(index)].flags |= AskFileRecord.removedFlag
                pinyin[index] = nil
                removed += 1
            }
            children[Int(directory)] = []
            directoryIndex[folder] = nil
            changed = true
        }
        return changed
    }

    /// Updates the modification date of an entry still there.
    mutating func touch(_ index: UInt32, modified: Date) {
        records[Int(index)].modified = Self.seconds(modified)
    }

    /// A copy without removed entries, when enough have gone that scanning them costs.
    func compacted() -> AskFileIndexState {
        var fresh = AskFileIndexState(home: home)
        var directoryMap: [UInt32: UInt32] = [:]
        // Directories in creation order: parents always come before their children.
        for (old, directory) in directories.enumerated() where directoryIndex[directory.path] == UInt32(old) {
            let parent = directoryMap[directory.parent] ?? AskFileDirectory.none
            directoryMap[UInt32(old)] = fresh.directory(directory.path, parent: parent)
        }
        for record in records where !record.isRemoved {
            guard let directory = directoryMap[record.directory] else { continue }
            let index = fresh.add(name: name(of: record), directory: directory, kind: record.recordKind,
                                  modified: Date(timeIntervalSinceReferenceDate: TimeInterval(record.modified)))
            let path = fresh.path(of: index)
            if let own = fresh.directoryIndex[path] { fresh.directories[Int(own)].record = index }
        }
        return fresh
    }

    var needsCompaction: Bool { removed > 1000 && removed * 5 > records.count }
}
