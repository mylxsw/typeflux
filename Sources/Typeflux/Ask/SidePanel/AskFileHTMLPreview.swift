import Darwin
import Foundation

/// Both local preview entrances snapshot the HTML's containing directory. Never widen
/// to the workspace or follow links. Only web assets enter the isolated preview origin.
enum AskFileHTMLPreview {
    static let entry = "index.html"
    static let extensions: Set<String> = [
        "html", "htm", "css", "js", "mjs", "png", "jpg", "jpeg", "gif", "webp", "svg", "ico",
        "woff", "woff2", "ttf", "otf"
    ]

    static func bundle(_ target: AskSidePanelFileAccess.Target, roots: [String]) throws -> AskArtifactBundle {
        try AskSidePanelFileAccess.check(target, roots: roots)
        let directory = try AskFileAccess.openRoot(target.url.deletingLastPathComponent().path)
        var files: [String: Data] = [:]
        var total = 0, visited = 0
        func visit(_ folder: AskSecureDirectory, prefix: String, depth: Int) throws {
            guard depth < 16 else { throw AskArtifactError.tooLarge }
            for name in folder.entries(limit: 1025).sorted() {
                visited += 1
                guard visited <= 1024 else { throw AskArtifactError.tooLarge }
                guard !name.hasPrefix("."), name != "node_modules" else { continue }
                let path = prefix + name
                var info = stat()
                guard fstatat(folder.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw AskArtifactError.unavailable
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    try visit(folder.child(name), prefix: path + "/", depth: depth + 1)
                } else if info.st_mode & S_IFMT == S_IFREG,
                          extensions.contains((name as NSString).pathExtension.lowercased()) {
                    try AskArtifactStore.validatePath(path)
                    guard files.count < AskArtifactStore.maximumFiles,
                          info.st_size <= AskArtifactStore.maximumFileBytes else { throw AskArtifactError.tooLarge }
                    let data = try folder.readFile(name, limit: AskArtifactStore.maximumFileBytes)
                    guard data.count <= AskArtifactStore.maximumBundleBytes - total else { throw AskArtifactError.tooLarge }
                    files[path] = data
                    total += data.count
                }
            }
        }
        try visit(directory, prefix: "", depth: 0)
        try AskSidePanelFileAccess.check(target, roots: roots)
        return try bundle(files: files, entry: target.name)
    }

    /// Self-contained HTML remains supported without granting filesystem authority.
    static func bundle(_ data: Data) throws -> AskArtifactBundle {
        try bundle(files: [entry: data], entry: entry)
    }

    private static func bundle(files: [String: Data], entry: String) throws -> AskArtifactBundle {
        guard let data = files[entry] else { throw AskArtifactError.unavailable }
        guard data.count <= AskArtifactStore.maximumFileBytes else { throw AskArtifactError.tooLarge }
        let resources = files.keys.sorted().map { path in
            AskArtifactResource(path: path, mediaType: AskPreviewPolicy.mediaType(path),
                                sizeBytes: files[path]!.count, sha256: AskToolPolicy.digest(files[path]!))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let version = AskToolPolicy.digest(try encoder.encode(resources))
        let ref = AskArtifactRef(id: UUID().uuidString.lowercased(), ownerId: "local-preview", conversationId: "",
                                 runId: "file-preview", version: version, mediaType: "text/html",
                                 sizeBytes: Int64(files.values.reduce(0) { $0 + $1.count }),
                                 sha256: AskToolPolicy.digest(data), cleanup: "none")
        return AskArtifactBundle(manifest: .init(ref: ref, workspace: nil, createdAt: Date(),
                                                entry: entry, resources: resources), files: files)
    }
}
