import Foundation

/// Provenance is informational. This type contains no execution grants or approval receipts.
struct AskSkillSource: Codable, Equatable, Sendable {
    static let fileName = ".source.json"

    struct Resource: Codable, Equatable, Sendable {
        var path: String
        var bytes: Int
        var sha256: String
    }

    var url: String
    var repository: String
    /// Requested branch/tag, preserved for display and future explicit updates.
    var ref: String
    var path: String
    var installedAt: Date
    // Optional fields decode legacy installations without inventing immutable provenance.
    var schemaVersion: Int? = 2
    var commit: String?
    var installationID: UUID?
    var version: String?
    var resources: [Resource]?
    var declaredPermissions: [String]?
}

extension AskSkillLibrary {
    func userSkillNames() -> [String] {
        skills().filter { $0.directory != nil }.map(\.name)
    }

    /// V1 metadata remains readable; the next explicit install writes the full V2 schema.
    func source(of skill: AskSkill) -> AskSkillSource? {
        guard let directory = skill.directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(AskSkillSource.fileName)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AskSkillSource.self, from: data)
    }

    func hasPreviousVersion(of skill: AskSkill) -> Bool {
        guard let directory = skill.directory, isUserDirectory(directory) else { return false }
        return FileManager.default.fileExists(atPath: userDirectory
            .appendingPathComponent(".previous/" + directory.lastPathComponent + "/SKILL.md").path)
    }

    func rollback(_ skill: AskSkill) throws {
        let directory = try mutableDirectory(of: skill)
        try AskSkillInstallationStore(directory: userDirectory).rollback(directory.lastPathComponent)
    }

    func remove(_ skill: AskSkill) throws {
        let directory = try mutableDirectory(of: skill)
        try AskSkillInstallationStore(directory: userDirectory).remove(directory.lastPathComponent)
    }

    private func isUserDirectory(_ directory: URL) -> Bool {
        directory.standardizedFileURL.deletingLastPathComponent().path == userDirectory.standardizedFileURL.path
            && AskSkillInstaller.isSafePathComponent(directory.lastPathComponent)
    }

    private func mutableDirectory(of skill: AskSkill) throws -> URL {
        guard let directory = skill.directory, isUserDirectory(directory) else {
            throw AskLocalError.message(L("ask.skills.install.cannotRemove"))
        }
        return directory
    }
}
