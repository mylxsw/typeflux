import Foundation

/// The editor's working copy of one workflow: `workflow.json` as text, so fields the
/// form does not know survive every edit, and the other text files in the folder.
/// See `docs/design/ask-workflow-editor.md` §5.
struct AskWorkflowDraft: Equatable, Sendable {
    /// The four things a workflow does, as the editor's flow strip shows them.
    enum Step: String, CaseIterable, Sendable {
        case keywords, input, script, output
    }

    /// Text files the editor opens; larger ones are left to an external editor.
    static let maximumFileSize = 1_000_000
    static let maximumFiles = 50

    var folder: URL
    /// `workflow.json`, exactly as the JSON view shows it.
    var manifestText: String
    /// Every other text file, by path relative to the folder.
    var files: [String: String]
    /// What is on disk, to tell which files changed.
    private(set) var savedManifestText: String
    private(set) var savedFiles: [String: String]
    /// Files the folder has that the editor does not open (images, binaries, large files).
    private(set) var otherFiles: [String]

    init(folder: URL, manifestText: String, files: [String: String], otherFiles: [String] = []) {
        self.folder = folder
        self.manifestText = manifestText
        self.files = files
        savedManifestText = manifestText
        savedFiles = files
        self.otherFiles = otherFiles
    }

    /// Reads a workflow folder: the manifest and every UTF-8 text file up to the size limit.
    static func load(folder: URL, fileManager: FileManager = .default) -> AskWorkflowDraft {
        let manifestURL = folder.appendingPathComponent(AskWorkflowManifest.fileName)
        let manifest = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
        var files: [String: String] = [:]
        var others: [String] = []
        let root = folder.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "__pycache__" {
                enumerator?.skipDescendants(); continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            guard path != AskWorkflowManifest.fileName else { continue }
            if files.count < maximumFiles, (values?.fileSize ?? 0) <= maximumFileSize,
               let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
               !text.contains("\u{0}") {
                files[path] = text
            } else {
                others.append(path)
            }
        }
        return AskWorkflowDraft(folder: folder, manifestText: manifest, files: files, otherFiles: others.sorted())
    }

    // MARK: - Changes

    var isDirty: Bool {
        manifestText != savedManifestText || files != savedFiles
    }

    /// Paths written since the last save; `workflow.json` included when the manifest changed.
    var changedPaths: [String] {
        var paths = files.filter { savedFiles[$0.key] != $0.value }.map(\.key)
        if manifestText != savedManifestText {
            paths.append(AskWorkflowManifest.fileName)
        }
        return paths.sorted()
    }

    /// The text files on disk when the draft was loaded or last saved.
    var savedPaths: [String] {
        savedFiles.keys.sorted()
    }

    /// Files removed since the last save.
    var deletedPaths: [String] {
        savedFiles.keys.filter { files[$0] == nil }.sorted()
    }

    func isDirty(_ path: String) -> Bool {
        path == AskWorkflowManifest.fileName ? manifestText != savedManifestText : files[path] != savedFiles[path]
    }

    /// What to write and remove to bring the folder to this draft.
    var pendingWrites: [String: Data] {
        var writes: [String: Data] = [:]
        for path in changedPaths {
            let text = path == AskWorkflowManifest.fileName ? manifestText : files[path] ?? ""
            writes[path] = Data(text.utf8)
        }
        return writes
    }

    /// The draft now matches the disk.
    mutating func markSaved() {
        savedManifestText = manifestText
        savedFiles = files
    }

    /// Every text file, the manifest first, for the file list.
    var paths: [String] {
        [AskWorkflowManifest.fileName] + files.keys.sorted()
    }

    func text(of path: String) -> String? {
        path == AskWorkflowManifest.fileName ? manifestText : files[path]
    }

    mutating func setText(_ text: String, of path: String) {
        if path == AskWorkflowManifest.fileName {
            manifestText = text
        } else {
            files[path] = text
        }
    }

    // MARK: - Manifest

    /// The manifest decoded from the text, or the reason it cannot be.
    var decoded: Result<AskWorkflowManifest, AskWorkflowDraftError> {
        guard let data = manifestText.data(using: .utf8), !manifestText.isEmpty else {
            return .failure(.syntax(L("ask.workflow.problem.noManifest")))
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.syntax(L("ask.workflow.problem.json")))
        }
        do {
            return try .success(JSONDecoder().decode(AskWorkflowManifest.self, from: data))
        } catch {
            return .failure(.decoding(AskWorkflow.describe(error)))
        }
    }

    var manifest: AskWorkflowManifest? {
        try? decoded.get()
    }

    /// The manifest parses as JSON: the form can edit it.
    var isFormEditable: Bool {
        guard let data = manifestText.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Everything that stops the workflow from running, as the folder would be with
    /// this draft saved: a script only in the draft counts as present.
    func problems(fileManager: FileManager = .default) -> [AskWorkflowManifest.Problem] {
        switch decoded {
        case let .failure(error):
            [AskWorkflowManifest.Problem(field: AskWorkflowManifest.fileName, message: error.message)]
        case let .success(manifest):
            manifest.problems(in: folder, fileManager: fileManager).filter { problem in
                guard problem.field == "command.script", let script = manifest.command.script else { return true }
                let missing = L("ask.workflow.problem.scriptMissing", script)
                let notExecutable = L("ask.workflow.problem.notExecutable", script)
                // The draft has it (or will mark it executable on save).
                return !(files[script] != nil && (problem.message == missing || problem.message == notExecutable))
            }
        }
    }

    /// Sets a value at a key path of the manifest (`["command", "script"]`), keeping
    /// every other field as it was. `nil` removes the key. Fails when the text is not
    /// a JSON object, so the form never overwrites what the user is typing.
    @discardableResult
    mutating func set(_ value: Any?, at path: [String]) -> Bool {
        guard !path.isEmpty, let data = manifestText.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        Self.assign(value, at: path[...], in: &object)
        guard let text = Self.format(object) else { return false }
        manifestText = text
        return true
    }

    /// The value at a key path, for the form.
    func value(at path: [String]) -> Any? {
        guard let data = manifestText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var current: Any? = object
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current
    }

    private static func assign(_ value: Any?, at path: ArraySlice<String>, in object: inout [String: Any]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            object[key] = value
            return
        }
        var child = object[key] as? [String: Any] ?? [:]
        assign(value, at: path.dropFirst(), in: &child)
        object[key] = child.isEmpty && value == nil ? nil : child
    }

    /// Pretty JSON with sorted keys, like the templates write.
    static func format(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8).map { $0 + "\n" }
    }

    /// Re-indents the manifest; nil when it is not valid JSON.
    func formattedManifest() -> String? {
        guard let data = manifestText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return Self.format(object)
    }

    // MARK: - Problems → places

    /// The flow step a manifest field belongs to.
    static func step(for field: String) -> Step? {
        let root = field.split(whereSeparator: { $0 == "." || $0 == "[" }).first.map(String.init) ?? field
        switch root {
        case "keywords": return .keywords
        case "input": return .input
        case "command": return .script
        case "output", "run", "env": return .output
        default: return nil
        }
    }

    /// The 1-based line of `workflow.json` that holds a field (`command.script`,
    /// `keywords[1]`), found by scanning for its keys in order. Nil when it is not there.
    func line(for field: String) -> Int? {
        let lines = manifestText.components(separatedBy: "\n")
        var start = 0
        var found: Int?
        for part in field.split(separator: ".") {
            var key = String(part)
            var index: Int?
            if let open = key.firstIndex(of: "["), let close = key.firstIndex(of: "]") {
                index = Int(key[key.index(after: open) ..< close])
                key = String(key[..<open])
            }
            guard let keyLine = lines[start...].firstIndex(where: { $0.contains("\"\(key)\"") }) else { return found }
            found = keyLine + 1
            start = keyLine
            // The nth element of a pretty-printed array: the nth line after the key that
            // opens an object. A one-line array stays on the key's line.
            if let index, !lines[keyLine].contains("]") {
                let opening = lines.indices.dropFirst(keyLine + 1).filter {
                    lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("{")
                }
                if index < opening.count {
                    found = opening[index] + 1
                    start = opening[index]
                }
            }
        }
        return found
    }
}

enum AskWorkflowDraftError: Error, Equatable, Sendable {
    /// Not JSON at all: the form is read-only until it is.
    case syntax(String)
    /// JSON, but not a manifest.
    case decoding(String)

    var message: String {
        switch self {
        case let .syntax(message), let .decoding(message): message
        }
    }
}
