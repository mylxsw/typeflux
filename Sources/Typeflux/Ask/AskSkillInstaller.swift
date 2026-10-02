import Foundation

/// Where a user skill was installed from, saved next to its SKILL.md.
struct AskSkillSource: Codable, Equatable, Sendable {
    static let fileName = ".source.json"

    var url: String
    var repository: String
    var ref: String
    var path: String
    var installedAt: Date
}

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

    struct Result: Equatable {
        var installed: [String]
        var replaced: [String]
    }

    var library: AskSkillLibrary
    var session: URLSession = .init(configuration: .ephemeral)
    var apiBase = URL(string: "https://api.github.com")!
    var rawBase = URL(string: "https://raw.githubusercontent.com")!
    var now: @Sendable () -> Date = Date.init

    // MARK: - URL parsing

    static func parse(_ input: String) throws -> Target {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host?.lowercased(),
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
        guard pathParts.allSatisfy(Self.isSafePathComponent) else {
            throw AskLocalError.message(L("ask.skills.install.invalidURL"))
        }
        return Target(owner: owner, repository: repository, ref: ref, path: pathParts.joined(separator: "/"))
    }

    private static func isSafeName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
            && value != "." && value != ".."
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("\\") && !value.hasPrefix(".")
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
        let files = try await tree(target, ref: ref)
        let skillFolders = Self.skillFolders(in: files, under: target.path)
        guard !skillFolders.isEmpty else { throw AskLocalError.message(L("ask.skills.install.notFound")) }
        guard skillFolders.count <= Self.maximumSkillsPerInstall else {
            throw AskLocalError.message(L("ask.skills.install.tooMany"))
        }
        let fileManager = FileManager.default
        // Stage beside the destination so the final move stays on one volume; hidden
        // folders are ignored by the skill list, so a half-finished install never shows.
        let staging = library.userDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var prepared: [(name: String, folder: URL)] = []
        for folder in skillFolders {
            // Hidden files (.git*, .github/…) are not part of a skill.
            let skillFiles = files.filter { folder.isEmpty || $0.path.hasPrefix(folder + "/") }
                .filter { Self.belongs($0.path, to: folder, otherSkills: skillFolders) }
                .filter { Self.relativePath($0.path, in: folder).split(separator: "/").map(String.init).allSatisfy(Self.isSafePathComponent) }
            guard skillFiles.count <= Self.maximumFilesPerSkill,
                  skillFiles.reduce(0, { $0 + $1.size }) <= Self.maximumSkillBytes,
                  skillFiles.allSatisfy({ $0.size <= Self.maximumFileBytes }) else {
                throw AskLocalError.message(L("ask.skills.install.tooLarge"))
            }
            let local = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
            for file in skillFiles {
                let components = Self.relativePath(file.path, in: folder).split(separator: "/").map(String.init)
                let destination = components.reduce(local) { $0.appendingPathComponent($1) }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await download(target, ref: ref, path: file.path).write(to: destination)
            }
            let skillFile = local.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skillFile, encoding: .utf8),
                  let skill = AskSkillLibrary.parse(text, fallbackName: folder.split(separator: "/").last.map(String.init) ?? target.repository) else {
                throw AskLocalError.message(L("ask.skills.install.invalidSkill"))
            }
            let source = AskSkillSource(url: input.trimmingCharacters(in: .whitespacesAndNewlines),
                                        repository: "\(target.owner)/\(target.repository)", ref: ref, path: folder, installedAt: now())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(source).write(to: local.appendingPathComponent(AskSkillSource.fileName))
            prepared.append((skill.name, local))
        }

        let names = prepared.map(\.name)
        guard Set(names).count == names.count else { throw AskLocalError.message(L("ask.skills.install.invalidSkill")) }
        let existing = Set(library.userSkillNames())
        let newCount = names.filter { !existing.contains($0) }.count
        guard existing.count + newCount <= AskSkillLibrary.maximumSkills else {
            throw AskLocalError.message(L("ask.skills.install.tooMany"))
        }

        var replaced: [String] = []
        for (name, folder) in prepared {
            let destination = library.userDirectory.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: folder)
                replaced.append(name)
            } else {
                try fileManager.moveItem(at: folder, to: destination)
            }
        }
        return Result(installed: names.sorted(), replaced: replaced.sorted())
    }

    /// Folders that hold a SKILL.md at or below `root` ("" means the repository root).
    static func skillFolders(in files: [RemoteFile], under root: String) -> [String] {
        files.compactMap { file -> String? in
            guard file.path == "SKILL.md" || file.path.hasSuffix("/SKILL.md") else { return nil }
            let folder = file.path == "SKILL.md" ? "" : String(file.path.dropLast("/SKILL.md".count))
            guard root.isEmpty || folder == root || folder.hasPrefix(root + "/") else { return nil }
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

    // MARK: - GitHub

    struct RemoteFile: Equatable {
        var path: String
        var size: Int
    }

    private func defaultBranch(_ target: Target) async throws -> String {
        let data = try await get(apiBase.appendingPathComponent("repos/\(target.owner)/\(target.repository)"))
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let branch = body["default_branch"] as? String, !branch.isEmpty else {
            throw AskLocalError.message(L("ask.skills.install.notFound"))
        }
        return branch
    }

    private func tree(_ target: Target, ref: String) async throws -> [RemoteFile] {
        var url = apiBase.appendingPathComponent("repos/\(target.owner)/\(target.repository)/git/trees/\(ref)")
        url = URL(string: url.absoluteString + "?recursive=1")!
        let data = try await get(url)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = body["tree"] as? [[String: Any]] else {
            throw AskLocalError.message(L("ask.skills.install.notFound"))
        }
        // Regular files only: symlinks (120000) and submodules (commit) are skipped.
        return entries.compactMap { entry in
            guard entry["type"] as? String == "blob", let path = entry["path"] as? String,
                  ["100644", "100755"].contains(entry["mode"] as? String ?? "") else { return nil }
            return RemoteFile(path: path, size: entry["size"] as? Int ?? 0)
        }
    }

    private func download(_ target: Target, ref: String, path: String) async throws -> Data {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let url = URL(string: "\(rawBase.absoluteString)/\(target.owner)/\(target.repository)/\(ref)/\(encoded)")!
        let data = try await get(url)
        guard data.count <= Self.maximumFileBytes else { throw AskLocalError.message(L("ask.skills.install.tooLarge")) }
        return data
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AskLocalError.message(L("ask.skills.install.network"))
        }
        guard let http = response as? HTTPURLResponse else { throw AskLocalError.message(L("ask.skills.install.network")) }
        switch http.statusCode {
        case 200 ..< 300: return data
        case 404: throw AskLocalError.message(L("ask.skills.install.notFound"))
        case 403, 429: throw AskLocalError.message(L("ask.skills.install.rateLimited"))
        default: throw AskLocalError.message(L("ask.skills.install.network"))
        }
    }
}

extension AskSkillLibrary {
    /// Names of skills installed in the user folder (built-ins excluded).
    func userSkillNames() -> [String] {
        skills().filter { $0.directory != nil }.map(\.name)
    }

    /// The GitHub source of an installed skill, if it was installed from a URL.
    func source(of skill: AskSkill) -> AskSkillSource? {
        guard let directory = skill.directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(AskSkillSource.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AskSkillSource.self, from: data)
    }

    /// Deletes a user skill's folder. Built-in skills cannot be removed.
    func remove(_ skill: AskSkill) throws {
        guard let directory = skill.directory,
              directory.standardizedFileURL.deletingLastPathComponent().path == userDirectory.standardizedFileURL.path else {
            throw AskLocalError.message(L("ask.skills.install.cannotRemove"))
        }
        try FileManager.default.removeItem(at: directory)
    }
}
