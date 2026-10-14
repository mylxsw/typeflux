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

    static let extensions: Set<String> = ["txt", "md", "markdown", "rst", "csv", "tsv", "pdf"]
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumChunks = 64
    static let dimension = 768
    /// Any vector-affecting change needs a new profile, forcing a coherent rebuild.
    static let profile = "embeddinggemma2-\(SemanticModel.sha256)-llama4d756bc-mean-l2-768-prompts1-utf8chunk1"

    static func allows(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        let forbidden: Set = [".ssh", ".aws", ".config", ".gnupg", ".git", "node_modules", ".build", "keychains"]
        guard path.hasPrefix("/"), AskFileScope.normalize(path) == path,
              !parts.contains(where: { forbidden.contains($0) || $0.hasPrefix(".env") }),
              let name = parts.last, !name.contains("credential"), !name.contains("secret"),
              !name.hasPrefix("id_rsa"), !name.hasPrefix("id_ed25519") else { return false }
        return self.extensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func scope(names: AskLauncherSearchSettings, fullDiskAccess: Bool) -> AskFileScope {
        var scope = AskFileScope(settings: names, fullDiskAccess: fullDiskAccess)
        scope.excludedFolderNames.formUnion([".ssh", ".aws", ".config", ".gnupg", ".git", "node_modules", ".build"])
        return scope
    }

    static func query(_ text: String, type: AskFileType = .all) -> String? {
        guard [.all, .document, .pdf, .sheet].contains(type), text.count <= 512, text.utf8.count <= 1400,
              !text.contains(where: \.isNewline) else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).filter { token in
            let value = token.lowercased()
            return !value.hasPrefix("ext:") && !value.hasPrefix("in:") && !value.hasPrefix(".")
        }
        let query = words.joined(separator: " ")
        guard query.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 2 else { return nil }
        return query
    }

    /// Same pretokenization for documents and queries, including CJK unigrams/bigrams.
    static func terms(_ text: String) -> String {
        var terms: [String] = [], word = "", previous: String?
        for scalar in text.lowercased().unicodeScalars {
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

struct SemanticPage: Codable, Equatable, Sendable { var text: String; var page: Int? }
struct SemanticChunk: Equatable, Sendable {
    var text: String
    var page: Int?
    static func make(_ pages: [SemanticPage]) -> [SemanticChunk] {
        var result: [SemanticChunk] = []
        for page in pages {
            let characters = Array(page.text)
            var start = 0
            while start < characters.count, result.count < SemanticFilePolicy.maximumChunks {
                var end = start, bytes = 0
                while end < characters.count, bytes + characters[end].utf8.count <= 1200 {
                    bytes += characters[end].utf8.count; end += 1
                }
                guard end > start else { break }
                let text = String(characters[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.append(.init(text: text, page: page.page))
                }
                if end == characters.count {
                    break
                }
                start = max(start + 1, end - min(40, end - start - 1))
            }
            if result.count == SemanticFilePolicy.maximumChunks {
                break
            }
        }
        return result
    }
}

protocol SemanticFileSearching: AnyObject, Sendable {
    @MainActor var isEnabled: Bool { get }
    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit]
}

extension SemanticFileSearching {
    @MainActor var isEnabled: Bool { true }
}

extension SemanticFilePolicy {
    static func merge(_ names: [AskFileHit], _ content: [AskFileHit], limit: Int) -> [AskFileHit] {
        var seen = Set<String>()
        guard !content.isEmpty else { return Array(names.prefix(max(0, limit))) }
        let named = Dictionary(names.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let content = content.map { named[$0.path] ?? $0 }
        let leading = Array(names.prefix(3))
        let tail = names.dropFirst(3)
        let strong = tail.filter { $0.match >= AskQuickResults.strongFileScore }
        let weak = tail.filter { $0.match < AskQuickResults.strongFileScore }
        return Array((leading + strong + content + weak)
            .filter { seen.insert($0.path).inserted }.prefix(max(0, limit)))
    }
}
