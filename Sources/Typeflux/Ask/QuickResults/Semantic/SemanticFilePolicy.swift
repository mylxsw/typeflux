import Foundation
import Metal

struct SemanticFileSettings: Codable, Equatable, Sendable {
    var enabled = false
}

extension SettingsStore {
    var semanticFileSearch: SemanticFileSettings {
        get {
            guard let data = defaults.data(forKey: "ask.search.semantic") else { return .init() }
            return (try? JSONDecoder().decode(SemanticFileSettings.self, from: data)) ?? .init()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "ask.search.semantic")
            }
            NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: self)
        }
    }
}

enum SemanticFilePolicy {
    static var supported: Bool {
        #if arch(arm64)
            if #available(macOS 14, *) {
                return MTLCreateSystemDefaultDevice() != nil
            }
        #endif
        return false
    }

    static let documentExtensions: Set<String> = ["txt", "md", "markdown", "rst", "csv", "tsv", "pdf"]
    static let extensions = documentExtensions.union(SemanticMediaPriority.extensions)
    /// Per-request extraction budget, never a file-size or total-chunk quota.
    static let contentBatchBytes = 32 * 1024
    static let dimension = 768
    /// Model-space changes rebuild globally; extraction and sampling are versioned by each job recipe.
    static let profile = "embeddinggemma2-\(SemanticModel.sha256)-llama4d756bc-mean-l2-768-prompts1-utf8chunk1"

    private static let temporaryPath = AskFileScope.canonical(FileManager.default.temporaryDirectory.path)

    static func isLegacyMediaArtifact(_ path: String) -> Bool {
        AskFileScope.isInside(path, temporaryPath)
            && path.dropFirst(temporaryPath.count).split(separator: "/").first?.hasPrefix("typeflux-media-") == true
    }

    /// The normal model directory is private. A custom directory may also contain user documents;
    /// exclude its owned artifacts precisely rather than excluding those documents with the database.
    static func isIndexArtifact(_ path: String, directory: String) -> Bool {
        if AskFileScope.isInside(path, SemanticModel.directory.path) {
            return true
        }
        if AskFileScope.isInside(path, directory) {
            let relative = path.dropFirst(directory.count).split(separator: "/").map(String.init)
            if relative.isEmpty {
                return true
            }
            let name = relative[0]
            if name == ".typeflux-media-cache" || name == "media-cache" {
                return true
            }
            if ["embeddinggemma-2-Q8_0.gguf", SemanticMediaModel.name].contains(name) {
                return true
            }
            if ["semantic-files.sqlite", "index-events.sqlite"].contains(where: {
                name == $0 || name == $0 + "-wal" || name == $0 + "-shm" || name == $0 + "-journal"
            }) {
                return true
            }
        }
        return isLegacyMediaArtifact(path)
    }

    static func allows(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        let forbidden: Set = [
            ".ssh",
            ".aws",
            ".config",
            ".gnupg",
            ".git",
            "node_modules",
            ".build",
            "keychains",
            ".typeflux-media-cache"
        ]
        guard path.hasPrefix("/"), AskFileScope.normalize(path) == path, !isLegacyMediaArtifact(path),
              !AskFileScope.isInside(path, SemanticModel.directory.path),
              !parts.contains(where: { forbidden.contains($0) || $0.hasPrefix(".env") }),
              let name = parts.last, !name.contains("credential"), !name.contains("secret"),
              !name.hasPrefix("id_rsa"), !name.hasPrefix("id_ed25519") else { return false }
        return extensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func scope(names: AskLauncherSearchSettings, fullDiskAccess: Bool) -> AskFileScope {
        var scope = AskFileScope(settings: names, fullDiskAccess: fullDiskAccess)
        scope.excludedFolderNames.formUnion([
            ".ssh",
            ".aws",
            ".config",
            ".gnupg",
            ".git",
            "node_modules",
            ".build",
            ".typeflux-media-cache"
        ])
        return scope
    }

    static func query(_ text: String, type: AskFileType = .all) -> String? {
        guard [.all, .document, .pdf, .sheet, .image, .audio, .video].contains(type),
              text.count <= 512, text.utf8.count <= 1400,
              !text.contains(where: \.isNewline) else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).filter { token in
            let value = token.lowercased()
            return !value.hasPrefix("ext:") && !value.hasPrefix("in:") && !value.hasPrefix(".")
        }
        let query = words.joined(separator: " ")
        guard query.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 2 else { return nil }
        return query
    }

    /// Prefer actual CJK words to single-character overlap when building the lexical query.
    static func searchTerms(_ text: String) -> [String] {
        let words = Set(terms(text).split(separator: " ").map(String.init))
        let stop: Set = ["the", "a", "an", "is", "are", "of", "to", "for", "in", "and", "how", "what"]
        return words.filter { word in
            !stop.contains(word) && !(word.unicodeScalars.count == 1
                && word.unicodeScalars.first?.properties.isIdeographic == true)
        }.sorted()
    }

    /// Same pretokenization for documents and queries, including CJK unigrams/bigrams.
    static func terms(_ text: String, legacy: Bool = false) -> String {
        var terms: [String] = [], word = "", previous: String?
        for scalar in (legacy ? text.lowercased() : SemanticSearchRanking.normalize(text)).unicodeScalars {
            let cjk = scalar.properties.isIdeographic || (0x3040 ... 0x30FF).contains(scalar.value)
                || (0xAC00 ... 0xD7AF).contains(scalar.value)
            if cjk {
                if !word.isEmpty {
                    terms.append(word); word = ""
                }
                let current = String(scalar)
                terms.append(current)
                if let previous {
                    terms.append(previous + current)
                }
                previous = current
            } else {
                previous = nil
                if CharacterSet.alphanumerics.contains(scalar) {
                    word.unicodeScalars.append(scalar)
                } else if !word.isEmpty {
                    terms.append(word); word = ""
                }
            }
        }
        if !word.isEmpty {
            terms.append(word)
        }
        return terms.joined(separator: " ")
    }
}

/// UTF-8 offset in the file, or in a PDF page's extracted text. Page is zero based in cursors.
struct SemanticContentCursor: Codable, Equatable, Sendable {
    var page = 0
    var offset: Int64 = 0
}

struct SemanticPage: Codable, Equatable, Sendable {
    var text: String
    var page: Int?
    var offset: Int64 = 0
}

struct SemanticChunk: Equatable, Sendable {
    var text: String
    var page: Int?
    var time: TimeInterval?
    var startOffset: Int64?
    var endOffset: Int64?

    static func make(_ pages: [SemanticPage]) -> [SemanticChunk] {
        var result: [SemanticChunk] = []
        for page in pages {
            // Scalars keep even a pathological multi-megabyte grapheme bounded and searchable.
            let scalars = Array(page.text.unicodeScalars)
            var start = 0, offset = page.offset
            while start < scalars.count {
                var end = start, bytes = 0
                while end < scalars.count, bytes + scalars[end].utf8.count <= 1200 {
                    bytes += scalars[end].utf8.count; end += 1
                }
                let text = String(String.UnicodeScalarView(scalars[start ..< end]))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.init(text: text, page: page.page,
                                        startOffset: offset, endOffset: offset + Int64(bytes)))
                }
                if end == scalars.count {
                    break
                }
                let next = max(start + 1, end - 40)
                offset += Int64(scalars[start ..< next].reduce(0) { $0 + $1.utf8.count })
                start = next
            }
        }
        return result
    }
}

protocol SemanticFileSearching: AnyObject, Sendable {
    @MainActor var isEnabled: Bool { get }
    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit]
    func search(_ text: String, type: AskFileType, limit: Int,
                progress: @escaping @MainActor @Sendable ([AskFileHit]) -> Void) async -> [AskFileHit]
    @MainActor func prepareForSearch()
    @MainActor func endSearch()
}

extension SemanticFileSearching {
    @MainActor var isEnabled: Bool {
        true
    }

    @MainActor func prepareForSearch() {}
    @MainActor func endSearch() {}
    func search(_ text: String, type: AskFileType, limit: Int,
                progress _: @escaping @MainActor @Sendable ([AskFileHit]) -> Void) async -> [AskFileHit] {
        await search(text, type: type, limit: limit)
    }
}

extension SemanticFilePolicy {
    static func merge(_ names: [AskFileHit], _ content: [AskFileHit], limit: Int) -> [AskFileHit] {
        var seen = Set<String>()
        guard !content.isEmpty else { return Array(names.prefix(max(0, limit))) }
        let named = Dictionary(names.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let passages = Dictionary(content.map { ($0.path, $0.evidence) }, uniquingKeysWith: { first, _ in first })
        let names = names.map { hit in
            var hit = hit
            if let evidence = passages[hit.path] {
                hit.evidence = evidence
            }
            return hit
        }
        let enriched = Dictionary(names.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let content = content.map { enriched[$0.path] ?? named[$0.path] ?? $0 }
        let leading = Array(names.prefix(3))
        let tail = names.dropFirst(3)
        let strong = tail.filter { $0.match >= AskQuickResults.strongFileScore }
        let weak = tail.filter { $0.match < AskQuickResults.strongFileScore }
        return Array((leading + strong + content + weak)
            .filter { seen.insert($0.path).inserted }.prefix(max(0, limit)))
    }
}
