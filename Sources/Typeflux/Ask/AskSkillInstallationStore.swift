import Darwin
import Foundation

/// Mutations are prepared in a sibling snapshot and published with one atomic directory swap.
/// A failed move (including the second or later skill) never changes the live library.
struct AskSkillInstallationStore: Sendable {
    var directory: URL
    var move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    func install(_ prepared: [(name: String, folder: URL)]) throws -> [String] {
        try mutate { snapshot in
            let manager = FileManager.default
            let existing = try manager.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
            var names = Set(existing.map(\.lastPathComponent))
            let replacements = try prepared.map {
                try existingDirectory(named: $0.name, in: existing,
                                      destination: snapshot.appendingPathComponent($0.name))
            }
            var replaced: [String] = []
            for (item, old) in zip(prepared, replacements) {
                let destination = snapshot.appendingPathComponent(item.name)
                let previous = snapshot.appendingPathComponent(".previous/" + item.name)
                if let old {
                    try removeIfPresent(previous)
                    try manager.createDirectory(at: previous.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                    try move(old, previous)
                    names.remove(old.lastPathComponent)
                    replaced.append(item.name)
                }
                try move(item.folder, destination)
                names.insert(item.name)
            }
            guard names.count <= AskSkillLibrary.maximumSkills else {
                throw AskLocalError.message(L("ask.skills.install.tooMany"))
            }
            return replaced.sorted()
        }
    }

    /// Local skills can declare a name different from their folder. Replace that folder too,
    /// rather than letting an older alias silently shadow the newly installed version.
    private func existingDirectory(named name: String, in entries: [URL], destination: URL) throws -> URL? {
        let matches = entries.filter { folder in
            guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) else {
                return false
            }
            return AskSkillLibrary.parse(text, fallbackName: folder.lastPathComponent)?.name == name
        }
        let destinationExists = FileManager.default.fileExists(atPath: destination.path)
        if destinationExists,
           let text = try? String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8),
           let skill = AskSkillLibrary.parse(text, fallbackName: name), skill.name != name {
            throw AskLocalError.message(L("ask.skills.install.nameConflict"))
        }
        guard matches.count <= 1,
              !destinationExists || matches.isEmpty || matches.first?.lastPathComponent.lowercased() == name else {
            throw AskLocalError.message(L("ask.skills.install.nameConflict"))
        }
        return matches.first ?? (destinationExists ? destination : nil)
    }

    func rollback(_ name: String) throws {
        try mutate { snapshot in
            let current = snapshot.appendingPathComponent(name)
            let previous = snapshot.appendingPathComponent(".previous/" + name)
            guard FileManager.default.fileExists(atPath: previous.appendingPathComponent("SKILL.md").path) else {
                throw AskLocalError.message(L("ask.skills.install.noPrevious"))
            }
            let temporary = snapshot.appendingPathComponent(".rollback-" + UUID().uuidString)
            try move(current, temporary)
            try move(previous, current)
            try move(temporary, previous)
        }
    }

    func remove(_ name: String) throws {
        try mutate { snapshot in
            try FileManager.default.removeItem(at: snapshot.appendingPathComponent(name))
            try removeIfPresent(snapshot.appendingPathComponent(".previous/" + name))
        }
    }

    private func mutate<T>(_ change: (URL) throws -> T) throws -> T {
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        // The lock lives outside the swapped directory. All application writers use this store.
        let lock = parent.appendingPathComponent("." + directory.lastPathComponent + ".lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(descriptor, LOCK_UN) }
        try rejectLinks(in: directory)
        let snapshot = parent.appendingPathComponent(
            "." + directory.lastPathComponent + "-snapshot-" + UUID().uuidString
        )
        defer { try? manager.removeItem(at: snapshot) }
        let existed = manager.fileExists(atPath: directory.path)
        if existed {
            try manager.copyItem(at: directory, to: snapshot)
        } else {
            try manager.createDirectory(at: snapshot, withIntermediateDirectories: false)
        }
        let result = try change(snapshot)
        // RENAME_SWAP either publishes the whole snapshot or leaves the original untouched.
        // No per-folder rollback operations can fail after publication.
        if existed {
            guard renameatx_np(AT_FDCWD, snapshot.path, AT_FDCWD, directory.path, UInt32(RENAME_SWAP)) == 0 else {
                throw posixError()
            }
        } else {
            try manager.moveItem(at: snapshot, to: directory)
        }
        return result
    }

    private func rejectLinks(in root: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: root.path, isDirectory: &isDirectory)
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw AskLocalError.message(L("ask.skills.install.unsafeResource"))
        }
        guard exists else { return }
        guard isDirectory.boolValue else { throw AskLocalError.message(L("ask.skills.install.unsafeResource")) }
        let items = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = items?.nextObject() as? URL {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw AskLocalError.message(L("ask.skills.install.unsafeResource"))
            }
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
