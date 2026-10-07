import Foundation

/// What a file search returns and how it ranks.
struct AskFileSearchOptions: Equatable, Sendable {
    enum Order: Equatable, Sendable {
        case relevance
        /// Most recently changed first, for file mode's ⌘S and an empty query.
        case recent
    }

    var limit = 6
    var fuzzy = true
    var type: AskFileType = .all
    var order: Order = .relevance
    /// How often each path was opened from the launcher.
    var usage: [String: Int] = [:]
    var now = Date()
    var cancellation: AskSearchCancellation?
}

/// Ranking and searching the index. `final score = match + recently changed +
/// opened from the launcher − folder depth`, see `docs/design/launcher-content-search.md` §3.4.
extension AskFileIndexState {
    /// A word that only matches the path, not the name, scores this.
    static let pathScore = 0.4
    static let chunkSize = 16384

    static func recencyBoost(modified: UInt32, now: Date) -> Double {
        let days = max(0, (now.timeIntervalSinceReferenceDate - Double(modified)) / 86400)
        return 0.06 * exp(-days / 14)
    }

    static func usageBoost(_ count: Int) -> Double { Double(min(count, 10)) * 0.005 }

    static func depthPenalty(_ depth: UInt16) -> Double { min(Double(depth) * 0.004, 0.04) }

    /// The best files for `query`, best first.
    func search(_ query: AskSearchQuery, options: AskFileSearchOptions) -> [AskFileHit] {
        guard options.limit > 0, !query.isEmpty, !records.isEmpty, options.cancellation?.isCancelled != true else { return [] }
        let extensionBytes = query.fileExtension.map { Array($0.lowercased().utf8) }
        let mask = query.mask
        let oneWord = query.words.count <= 1
        // Group usage by directory once. Looking up each used path with
        // record(at:) would repeatedly scan large directories. Names are only
        // decoded for matching entries in directories with recorded usage.
        var usage: [UInt32: [String: Double]] = [:]
        for (path, count) in options.usage {
            guard options.cancellation?.isCancelled != true else { return [] }
            let folder = (path as NSString).deletingLastPathComponent
            if let directory = directoryIndex[folder] {
                usage[directory, default: [:]][(path as NSString).lastPathComponent] = Self.usageBoost(count)
            }
        }
        let chunks = (records.count + Self.chunkSize - 1) / Self.chunkSize
        var found = [[(score: Double, index: UInt32)]](repeating: [], count: chunks)
        let lock = NSLock()
        let context = ScanContext(query: query, mask: mask, wordMasks: query.words.prefix(64).map { AskSearchText.mask($0) },
                                  oneWord: oneWord, extensionBytes: extensionBytes, options: options, usage: usage)
        records.withUnsafeBufferPointer { records in
            keys.withUnsafeBufferPointer { keys in
                starts.withUnsafeBufferPointer { starts in
                    directoryMasks.withUnsafeBufferPointer { directoryMasks in
                        directoryDepths.withUnsafeBufferPointer { directoryDepths in
                            query.compact.withUnsafeBufferPointer { compact in
                                let tables = ScanTables(records: records, keys: keys, starts: starts,
                                                        directoryMasks: directoryMasks,
                                                        directoryDepths: directoryDepths, compact: compact)
                                // Leave CPU headroom for drawing and the independent app query.
                                let workers = min(4, chunks)
                                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                                    for chunk in stride(from: worker, to: chunks, by: workers) {
                                        guard options.cancellation?.isCancelled != true else { return }
                                        let local = scan(chunk: chunk, tables, context)
                                        lock.withLock { found[chunk] = local }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard options.cancellation?.isCancelled != true else { return [] }
        let matched = Array(found.joined())
        var candidates = matched.map { candidate in
            (score: candidate.score, index: candidate.index, path: self.path(of: candidate.index))
        }
        switch options.order {
        case .relevance:
            candidates.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let left = records[Int(lhs.index)].nameLength, right = records[Int(rhs.index)].nameLength
                return left != right ? left < right : lhs.path < rhs.path
            }
        case .recent:
            candidates.sort { lhs, rhs in
                let left = records[Int(lhs.index)].modified, right = records[Int(rhs.index)].modified
                return left != right ? left > right : lhs.index < rhs.index
            }
        }
        guard options.cancellation?.isCancelled != true else { return [] }
        return candidates.prefix(options.limit).map { hit(for: $0.index, path: $0.path, score: $0.score, query: query) }
    }

    /// The most recently changed entries, for file mode with nothing typed.
    func recent(options: AskFileSearchOptions) -> [AskFileHit] {
        guard options.limit > 0, options.cancellation?.isCancelled != true else { return [] }
        var best = AskSearchTopK<(modified: UInt32, index: UInt32)>(limit: options.limit) { lhs, rhs in
            lhs.modified != rhs.modified ? lhs.modified > rhs.modified : lhs.index < rhs.index
        }
        keys.withUnsafeBufferPointer { keys in
            for (position, record) in records.enumerated() {
                if position % 256 == 0, options.cancellation?.isCancelled == true { return }
                guard !record.isRemoved, record.recordKind != .folder else { continue }
                if options.type != .all,
                   !options.type.matches(kind: record.recordKind, extension: Self.fileExtension(record, keys)) { continue }
                best.insert((record.modified, UInt32(position)))
            }
        }
        guard options.cancellation?.isCancelled != true else { return [] }
        return best.sorted.map { candidate in
            let record = records[Int(candidate.index)]
            return AskFileHit(path: path(of: candidate.index), name: name(of: record), kind: record.recordKind,
                              modified: Date(timeIntervalSinceReferenceDate: TimeInterval(record.modified)), score: 0)
        }
    }

    // MARK: - Scoring

    private struct ScanContext {
        var query: AskSearchQuery
        var mask: UInt64
        /// Each word's characters: a word can only match a name whose mask covers them.
        var wordMasks: [UInt64]
        var oneWord: Bool
        var extensionBytes: [UInt8]?
        var options: AskFileSearchOptions
        var usage: [UInt32: [String: Double]]
    }

    private struct ScanTables {
        var records: UnsafeBufferPointer<AskFileRecord>
        var keys: UnsafeBufferPointer<UInt8>
        var starts: UnsafeBufferPointer<UInt8>
        var directoryMasks: UnsafeBufferPointer<UInt64>
        var directoryDepths: UnsafeBufferPointer<UInt16>
        var compact: UnsafeBufferPointer<UInt8>
    }

    /// One chunk of the table: every entry that matches, with its score so far.
    /// Entries sit in the order they were found, so neighbours share a folder:
    /// what the folder's path matches is worked out once per run of them.
    private func scan(chunk: Int, _ tables: ScanTables, _ context: ScanContext) -> [(score: Double, index: UInt32)] {
        var local = AskSearchTopK<(score: Double, index: UInt32)>(limit: context.options.limit) { lhs, rhs in
            let left = tables.records[Int(lhs.index)], right = tables.records[Int(rhs.index)]
            if context.options.order == .recent {
                return left.modified != right.modified ? left.modified > right.modified : lhs.index < rhs.index
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if left.nameLength != right.nameLength { return left.nameLength < right.nameLength }
            return path(of: lhs.index) < path(of: rhs.index)
        }
        let end = min(tables.records.count, (chunk + 1) * Self.chunkSize)
        let type = context.options.type
        var folderDirectory = -1
        var folderMatches = true
        var wordsDirectory = -1
        var wordsInPath: UInt64 = 0
        let needsPathWords = context.query.words.count > 1
        for position in chunk * Self.chunkSize ..< end {
            if position % 256 == 0, context.options.cancellation?.isCancelled == true { return [] }
            let record = tables.records[position]
            if record.isRemoved { continue }
            let directory = Int(record.directory)
            let reach = context.oneWord ? record.mask : record.mask | tables.directoryMasks[directory]
            if reach & context.mask != context.mask { continue }
            if type != .all, !type.matches(kind: record.recordKind, extension: Self.fileExtension(record, tables.keys)) {
                continue
            }
            if let ext = context.extensionBytes, !Self.hasExtension(record, ext, tables.keys) { continue }
            if let folder = context.query.folder {
                if directory != folderDirectory {
                    folderDirectory = directory
                    folderMatches = Self.contains(directories[directory].key, folder)
                }
                if !folderMatches { continue }
            }
            if needsPathWords {
                if directory != wordsDirectory {
                    wordsDirectory = directory
                    wordsInPath = pathWords(context.query.words, in: directory)
                }
                // Every word must be able to match the name or be in the path, before any matching.
                var reachable = true
                for (index, wordMask) in context.wordMasks.enumerated()
                    where record.mask & wordMask != wordMask && wordsInPath & (1 << UInt64(index)) == 0 {
                    reachable = false
                    break
                }
                if !reachable { continue }
            }
            guard let base = score(record, UInt32(position), tables, context, wordsInPath: wordsInPath) else { continue }
            let ranked = base + Self.recencyBoost(modified: record.modified, now: context.options.now)
                - Self.depthPenalty(tables.directoryDepths[directory]) + (context.usage[record.directory]?[name(of: record)] ?? 0)
            local.insert((ranked, UInt32(position)))
        }
        return local.items
    }

    /// Which of the words (by bit, the first 64) the folder's path contains.
    private func pathWords(_ words: [[UInt8]], in directory: Int) -> UInt64 {
        let key = directories[directory].key
        var bits: UInt64 = 0
        for (index, word) in words.prefix(64).enumerated() where Self.contains(key, word) { bits |= 1 << UInt64(index) }
        return bits
    }

    /// The match score for one entry: the whole query in the name, else every word
    /// in the name or the path, averaged. Nil when a word matches neither.
    private func score(_ record: AskFileRecord, _ index: UInt32, _ tables: ScanTables, _ context: ScanContext,
                       wordsInPath: UInt64) -> Double? {
        let query = context.query
        if query.words.isEmpty { return 0.5 }
        let keyStart = Int(record.keyOffset), startsStart = Int(record.startsOffset)
        let name = UnsafeBufferPointer(rebasing: tables.keys[keyStart ..< keyStart + Int(record.keyLength)])
        let wordStarts = UnsafeBufferPointer(rebasing: tables.starts[startsStart ..< startsStart + Int(record.startsCount)])
        let ext = record.extensionStart > 0 ? Int(record.extensionStart) : nil
        let pinyin = record.hasPinyin ? self.pinyin[index] : nil
        let fuzzy = context.options.fuzzy
        if record.mask & context.mask == context.mask,
           let whole = AskFuzzyMatcher.match(tables.compact, name: name, wordStarts: wordStarts, extensionStart: ext,
                                             pinyin: pinyin, fuzzy: fuzzy) {
            if tables.compact.count == 1, whole.score < AskFuzzyMatcher.wordPrefix { return nil }
            return whole.score
        }
        guard query.words.count > 1 else { return nil }
        var total = 0.0
        for (position, word) in query.words.enumerated() {
            let inName = position >= context.wordMasks.count
                || record.mask & context.wordMasks[position] == context.wordMasks[position]
            let found = !inName ? nil : word.withUnsafeBufferPointer {
                AskFuzzyMatcher.match($0, name: name, wordStarts: wordStarts, extensionStart: ext, pinyin: pinyin,
                                      fuzzy: fuzzy)
            }
            if let found {
                total += found.score
            } else if position < 64, wordsInPath & (1 << UInt64(position)) != 0 {
                total += Self.pathScore
            } else {
                return nil
            }
        }
        return total / Double(query.words.count)
    }

    /// A result with the matched characters of its name marked.
    private func hit(for index: UInt32, path: String, score: Double, query: AskSearchQuery) -> AskFileHit {
        let record = records[Int(index)]
        let name = name(of: record)
        var ranges: [Range<Int>] = []
        var match = 0.0
        let key = AskSearchKey(name, hasExtension: record.recordKind != .folder)
        if query.words.isEmpty {
            match = 0.5
        } else if let whole = AskFuzzyMatcher.match(query.compact, key, ranges: true) {
            ranges = whole.ranges
            match = whole.score
        } else {
            for word in query.words {
                let found = AskFuzzyMatcher.match(word, key, ranges: true)
                ranges += found?.ranges ?? []
                match += found?.score ?? Self.pathScore
            }
            match /= Double(query.words.count)
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        return AskFileHit(path: path, name: name, kind: record.recordKind,
                          modified: Date(timeIntervalSinceReferenceDate: TimeInterval(record.modified)), score: score,
                          match: match, highlights: AskSearchText.characterRanges(ranges, in: name))
    }

    // MARK: - Bytes

    static func fileExtension(_ record: AskFileRecord, _ keys: UnsafeBufferPointer<UInt8>) -> String {
        guard record.extensionStart > 0 else { return "" }
        let start = Int(record.keyOffset) + Int(record.extensionStart) + 1
        let end = Int(record.keyOffset) + Int(record.keyLength)
        guard start < end else { return "" }
        return String(decoding: keys[start ..< end], as: UTF8.self)
    }

    private static func hasExtension(_ record: AskFileRecord, _ ext: [UInt8], _ keys: UnsafeBufferPointer<UInt8>) -> Bool {
        guard record.extensionStart > 0 else { return false }
        let start = Int(record.keyOffset) + Int(record.extensionStart) + 1
        let end = Int(record.keyOffset) + Int(record.keyLength)
        guard end - start == ext.count else { return false }
        for (offset, byte) in ext.enumerated() where keys[start + offset] != byte { return false }
        return true
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        let first = needle[0]
        outer: for start in 0 ... haystack.count - needle.count where haystack[start] == first {
            for offset in 1 ..< needle.count where haystack[start + offset] != needle[offset] { continue outer }
            return true
        }
        return false
    }
}
