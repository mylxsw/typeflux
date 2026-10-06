import CryptoKit
import Foundation

/// An installed workflow: its folder, its manifest (or why it has none), and
/// whether it may run.
struct AskWorkflow: Equatable, Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        case ready
        /// Never confirmed: imported, or copied into the folder by hand.
        case untrusted
        /// Its files changed since it was confirmed.
        case modified
        case invalid([AskWorkflowManifest.Problem])
        case disabled
    }

    /// The folder name when the manifest cannot be read, else the manifest's id.
    var id: String
    var folder: URL
    var manifest: AskWorkflowManifest?
    var status: Status
    /// The SHA-256 of every file in the folder, for trust.
    var hash: String

    /// Why it cannot run now, or nil when it can.
    var blockedReason: String? {
        switch status {
        case .ready: nil
        case .untrusted: L("ask.workflow.blocked.untrusted")
        case .modified: L("ask.workflow.blocked.modified")
        case let .invalid(problems): L("ask.workflow.blocked.invalid", problems.first?.message ?? "")
        case .disabled: L("ask.workflow.blocked.disabled")
        }
    }

    /// The manifest's `sf:` icon, or one for its language.
    var symbol: String {
        if let icon = manifest?.icon, icon.hasPrefix("sf:") { return String(icon.dropFirst(3)) }
        switch manifest?.command.runtime {
        case .zsh, .bash: return "terminal"
        case .osascript: return "applescript"
        case .exec: return "gearshape.2"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    static func root(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Typeflux/Workflows", isDirectory: true)
    }

    static func dataDirectory(for id: String, home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Typeflux/WorkflowData/" + id,
                                                          isDirectory: true)
    }

    static func cacheDirectory(for id: String, home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/Typeflux/Workflows/" + id, isDirectory: true)
    }

    /// Reads one workflow folder. `trusted` is the hash the user confirmed, if any.
    static func load(folder: URL, trusted: String?, disabled: Bool, fileManager: FileManager = .default) -> AskWorkflow {
        let hash = contentHash(of: folder, fileManager: fileManager)
        let file = folder.appendingPathComponent(AskWorkflowManifest.fileName)
        let name = folder.lastPathComponent
        guard let data = try? Data(contentsOf: file) else {
            return AskWorkflow(id: name, folder: folder, manifest: nil, hash: hash, status: .invalid([
                AskWorkflowManifest.Problem(field: AskWorkflowManifest.fileName, message: L("ask.workflow.problem.noManifest"))
            ]))
        }
        let manifest: AskWorkflowManifest
        do {
            manifest = try JSONDecoder().decode(AskWorkflowManifest.self, from: data)
        } catch {
            return AskWorkflow(id: name, folder: folder, manifest: nil, hash: hash, status: .invalid([
                AskWorkflowManifest.Problem(field: AskWorkflowManifest.fileName, message: describe(error))
            ]))
        }
        let problems = manifest.problems(in: folder, fileManager: fileManager)
        let status: Status = if !problems.isEmpty {
            .invalid(problems)
        } else if disabled {
            .disabled
        } else if trusted == nil {
            .untrusted
        } else if trusted != hash {
            .modified
        } else {
            .ready
        }
        return AskWorkflow(id: manifest.id, folder: folder, manifest: manifest, hash: hash, status: status)
    }

    private init(id: String, folder: URL, manifest: AskWorkflowManifest?, hash: String, status: Status) {
        self.id = id
        self.folder = folder
        self.manifest = manifest
        self.hash = hash
        self.status = status
    }

    /// What a JSON decoding error is about, in a sentence that names the field.
    static func describe(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return L("ask.workflow.problem.missingField", (context.codingPath + [key]).map(\.stringValue).joined(separator: "."))
        case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            return L("ask.workflow.problem.wrongValue", context.codingPath.map(\.stringValue).joined(separator: "."))
        case let DecodingError.dataCorrupted(context) where !context.codingPath.isEmpty:
            return L("ask.workflow.problem.wrongValue", context.codingPath.map(\.stringValue).joined(separator: "."))
        default:
            return L("ask.workflow.problem.json")
        }
    }

    /// A SHA-256 over every file's relative path and contents (a link's target),
    /// in path order. Finder's `.DS_Store` and Python's bytecode caches do not count.
    static func contentHash(of folder: URL, fileManager: FileManager = .default) -> String {
        enum Entry { case file(URL), link(String) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let root = folder.standardizedFileURL.path
        let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys, options: [],
                                                errorHandler: { _, _ in true })
        var entries: [(path: String, entry: Entry)] = []
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if name == "__pycache__" { enumerator?.skipDescendants(); continue }
            if name == ".DS_Store" { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = String(url.standardizedFileURL.path.dropFirst(root.count))
            if values?.isSymbolicLink == true {
                entries.append((path, .link((try? fileManager.destinationOfSymbolicLink(atPath: url.path)) ?? "")))
            } else if values?.isRegularFile == true {
                entries.append((path, .file(url)))
            }
        }
        var hasher = SHA256()
        for (path, entry) in entries.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(path.utf8 + [0]))
            switch entry {
            case let .link(target):
                hasher.update(data: Data(("link:" + target).utf8))
            case let .file(url):
                if let handle = try? FileHandle(forReadingFrom: url) {
                    while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty { hasher.update(data: chunk) }
                    try? handle.close()
                }
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The last runs of each workflow, for settings. Inputs and outputs are not kept.
@MainActor
final class AskWorkflowLog: ObservableObject {
    struct Entry: Equatable, Sendable {
        var workflowID: String
        var keyword: String
        var date: Date
        var duration: Double
        var exitCode: Int32
        var timedOut: Bool
        /// The end of stderr, where scripts say what went wrong.
        var stderr: String
    }

    static let shared = AskWorkflowLog()
    static let limit = 20
    @Published private(set) var entries: [String: [Entry]] = [:]

    func add(_ entry: Entry) {
        var list = entries[entry.workflowID] ?? []
        list.insert(entry, at: 0)
        entries[entry.workflowID] = Array(list.prefix(Self.limit))
    }

    func last(for id: String) -> Entry? { entries[id]?.first }

    func clear(_ id: String) { entries[id] = nil }
}
