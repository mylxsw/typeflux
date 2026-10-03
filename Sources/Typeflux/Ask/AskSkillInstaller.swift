import Foundation

/// Installs skills from GitHub into the user Skills folder.
///
/// Accepts a repository (`github.com/owner/repo`), a folder (`…/tree/<ref>/<path>`) or a
/// SKILL.md file (`…/blob/<ref>/<path>/SKILL.md`). Every folder at or below the target that
/// holds a SKILL.md becomes one skill. Files are downloaded into a staging folder, the
/// SKILL.md is validated, and only then is the skill moved into place, replacing an older
/// copy with the same name.
struct AskSkillInstaller: Sendable {
    static let maximumFilesPerSkill = 50
    static let maximumFileBytes = 1_000_000
    static let maximumSkillBytes = 5_000_000
    static let maximumSkillsPerInstall = 20

    struct Target: Equatable {
        var owner: String
        var repository: String
        /// Branch, tag or commit; nil means the default branch.
        var ref: String?
        var path: String
    }

    private struct Source {
        var target: Target
        var input: String
        var ref: String
        var commit: String
    }

    struct Result: Equatable {
        var installed: [String]
        var replaced: [String]
    }

    var library: AskSkillLibrary
    var session: URLSession = .init(configuration: .ephemeral)
    var apiBase = URL(string: "https://api.github.com")!
    var rawBase = URL(string: "https://raw.githubusercontent.com")!
    var move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    var now: @Sendable () -> Date = { Date() }

    // MARK: - URL parsing

    static func parse(_ input: String) throws -> Target {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host?.lowercased(),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              host == "github.com" || host == "www.github.com" else {
            throw AskLocalError.message(L("ask.skills.install.invalidURL"))
        }
        var parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw AskLocalError.message(L("ask.skills.install.invalidURL")) }
        let owner = parts.removeFirst()
        var repository = parts.removeFirst()
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        guard Self.isSafeName(owner), Self.isSafeName(repository) else {
            throw AskLocalError.message(L("ask.skills.install.invalidURL"))
        }
        guard !parts.isEmpty else { return Target(owner: owner, repository: repository, ref: nil, path: "") }
        guard parts.count >= 2, parts[0] == "tree" || parts[0] == "blob" else {
            throw AskLocalError.message(L("ask.skills.install.invalidURL"))
        }
        let isFile = parts[0] == "blob"
        let ref = parts[1]
        var pathParts = Array(parts.dropFirst(2))
        if isFile {
            guard pathParts.last == "SKILL.md" else { throw AskLocalError.message(L("ask.skills.install.invalidURL")) }
            pathParts.removeLast()
        }
        guard Self.isSafePathComponent(ref), pathParts.allSatisfy(Self.isSafePathComponent) else {
            throw AskLocalError.message(L("ask.skills.install.invalidURL"))
        }
        return Target(owner: owner, repository: repository, ref: ref, path: pathParts.joined(separator: "/"))
    }

    private static func isSafeName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
            && value != "." && value != ".."
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("\\") && !value.contains("/") && !value.hasPrefix(".")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    // MARK: - Install

    func install(from input: String) async throws -> Result {
        let target = try Self.parse(input)
        let ref: String
        if let explicit = target.ref {
            ref = explicit
        } else {
            ref = try await defaultBranch(target)
        }
        let commit = try await resolveCommit(target, ref: ref)
        let files = try await tree(target, commit: commit)
        let skillFolders = Self.skillFolders(in: files, under: target.path)
        guard !skillFolders.isEmpty else { throw AskLocalError.message(L("ask.skills.install.notFound")) }
        guard skillFolders.count <= Self.maximumSkillsPerInstall else {
            throw AskLocalError.message(L("ask.skills.install.tooMany"))
        }
        let manager = FileManager.default
        let staging = library.userDirectory.deletingLastPathComponent()
            .appendingPathComponent(".skill-download-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let source = Source(target: target, input: input, ref: ref, commit: commit)
        var prepared: [(name: String, folder: URL)] = []
        for folder in skillFolders {
            prepared.append(try await prepare(folder, folders: skillFolders, files: files,
                                              source: source, staging: staging))
        }
        let names = prepared.map(\.name)
        guard Set(names).count == names.count else { throw AskLocalError.message(L("ask.skills.install.invalidSkill")) }
        try Task.checkCancellation()
        let replaced = try AskSkillInstallationStore(directory: library.userDirectory, move: move).install(prepared)
        return Result(installed: names.sorted(), replaced: replaced)
    }

    private func prepare(_ folder: String, folders: [String], files: [RemoteFile], source: Source,
                         staging: URL) async throws -> (name: String, folder: URL) {
        let selected = files.filter { Self.belongs($0.path, to: folder, otherSkills: folders) }
        guard selected.allSatisfy({ ["100644", "100755"].contains($0.mode) }) else {
            throw AskLocalError.message(L("ask.skills.install.unsafeResource"))
        }
        let skillFiles = selected.filter {
            Self.relativePath($0.path, in: folder).split(separator: "/").map(String.init)
                .allSatisfy(Self.isSafePathComponent)
        }
        guard skillFiles.count <= Self.maximumFilesPerSkill,
              skillFiles.allSatisfy({ $0.size >= 0 && $0.size <= Self.maximumFileBytes }),
              skillFiles.reduce(0, { $0 + $1.size }) <= Self.maximumSkillBytes else {
            throw AskLocalError.message(L("ask.skills.install.tooLarge"))
        }
        let manager = FileManager.default
        let local = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var resources: [AskSkillSource.Resource] = []
        for file in skillFiles {
            let relative = Self.relativePath(file.path, in: folder)
            let destination = local.appendingPathComponent(relative)
            try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            let data = try await download(source.target, commit: source.commit, file: file)
            try data.write(to: destination)
            resources.append(.init(path: relative, bytes: data.count, sha256: Self.sha256(data)))
        }
        let skillFile = local.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else {
            throw AskLocalError.message(L("ask.skills.install.invalidSkill"))
        }
        let skill: AskSkill
        do {
            skill = try AskSkillParser.parse(text, fallbackName: folder.split(separator: "/").last.map(String.init)
                                            ?? source.target.repository)
        } catch AskSkillParser.Failure.invalidSkill {
            throw AskLocalError.message(L("ask.skills.install.invalidSkill"))
        }
        let metadata = AskSkillSource(url: source.input.trimmingCharacters(in: .whitespacesAndNewlines),
                                    repository: "\(source.target.owner)/\(source.target.repository)", ref: source.ref,
                                    path: folder, installedAt: now(), commit: source.commit, installationID: UUID(),
                                    version: skill.version, resources: resources.sorted { $0.path < $1.path },
                                    declaredPermissions: skill.declaredPermissions)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: local.appendingPathComponent(AskSkillSource.fileName))
        return (skill.name, local)
    }

    /// Folders that hold a SKILL.md at or below `root` ("" means the repository root).
    static func skillFolders(in files: [RemoteFile], under root: String) -> [String] {
        files.compactMap { file -> String? in
            guard file.path == "SKILL.md" || file.path.hasSuffix("/SKILL.md") else { return nil }
            let folder = file.path == "SKILL.md" ? "" : String(file.path.dropLast("/SKILL.md".count))
            guard folder.split(separator: "/").map(String.init).allSatisfy(Self.isSafePathComponent),
                  root.isEmpty || folder == root || folder.hasPrefix(root + "/") else { return nil }
            return folder
        }.sorted()
    }

    static func relativePath(_ path: String, in folder: String) -> String {
        folder.isEmpty ? path : String(path.dropFirst(folder.count + 1))
    }

    /// A file belongs to the deepest skill folder that contains it, so nested skills stay separate.
    static func belongs(_ path: String, to folder: String, otherSkills: [String]) -> Bool {
        let owner = otherSkills.filter { $0.isEmpty || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        return owner == folder
    }

}
