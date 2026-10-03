import Darwin
import Foundation

struct AskProjectScope: Equatable {
    var ownerId: String
    var conversationId: String
    var runId: String
}

/// A controlled change manifest for both Git and ordinary folders. Source roots
/// are never written, reset, cleaned, or deleted. This does not launch programs.
final class AskProjectWorkspace {
    static let maximumChangeBytes = 4 * 1024 * 1024
    let storageURL: URL

    init(storageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Typeflux/AskProjects")) {
        self.storageURL = storageURL
    }

    private func source(_ root: String, authorizedRoots: [String]) throws -> AskProjectFileAccess {
        let normalized = AskProjectFileAccess.normalizedRoot(root)
        let storage = AskProjectFileAccess.normalizedRoot(storageURL.path)
        guard normalized != "/", normalized == root,
              authorizedRoots.map(AskProjectFileAccess.normalizedRoot).contains(root),
              !storage.hasPrefix(root + "/"), !root.hasPrefix(storage + "/"), root != storage else {
            throw AskProjectError.denied
        }
        return try .init(directory: AskSecureDirectory.openRoot(
            URL(fileURLWithPath: root),
            create: false,
            privateRoot: false
        ))
    }

    func reference(root: String, scope: AskProjectScope,
                   authorizedRoots: [String]) throws -> (AskWorkspaceRef, String) {
        guard ![scope.ownerId, scope.conversationId, scope.runId].contains(where: \.isEmpty)
        else { throw AskProjectError.denied }
        let root = AskProjectFileAccess.normalizedRoot(root)
        let access = try source(root, authorizedRoots: authorizedRoots)
        let identity = try AskProjectFileAccess.identity(access.directory)
        let key = try JSONEncoder().encode([scope.ownerId, scope.conversationId, scope.runId, root, identity])
        let id = String(AskToolPolicy.digest(key).dropFirst(7))
        return (.init(id: id, ownerId: scope.ownerId, conversationId: scope.conversationId,
                      runId: scope.runId, version: "initial", cleanup: "user_managed"), identity)
    }

    func open(root: String, scope: AskProjectScope, authorizedRoots: [String]) throws -> AskWorkspaceRef {
        let root = AskProjectFileAccess.normalizedRoot(root)
        let (ref, identity) = try reference(root: root, scope: scope, authorizedRoots: authorizedRoots)
        let storage = try AskSecureDirectory.openRoot(storageURL)
        let directory = try storage.child(ref.id, create: true, privateDirectory: true)
        try directory.lock()
        if directory.entries().contains("changes.json") {
            let existing = try load(directory)
            try validate(existing, id: ref.id, scope: scope, authorizedRoots: authorizedRoots)
            return existing.workspace
        }
        let changeSet = AskProjectChangeSet(workspace: ref, root: root, rootIdentity: identity)
        try save(changeSet, in: directory)
        return ref
    }

    private func validate(
        _ state: AskProjectChangeSet,
        id: String,
        scope: AskProjectScope,
        authorizedRoots: [String]
    ) throws {
        guard state.workspace.id == id, state.workspace.ownerId == scope.ownerId,
              state.workspace.conversationId == scope.conversationId, state.workspace.runId == scope.runId,
              state.workspace.cleanup == "user_managed" else { throw AskProjectError.denied }
        let access = try source(state.root, authorizedRoots: authorizedRoots)
        guard try AskProjectFileAccess.identity(access.directory) == state.rootIdentity
        else { throw AskProjectError.conflict }
    }

    private func load(_ directory: AskSecureDirectory) throws -> AskProjectChangeSet {
        let state = try JSONDecoder().decode(
            AskProjectChangeSet.self,
            from: directory.readFile("changes.json", limit: 12 * 1024 * 1024)
        )
        guard state.entries.count <= 100,
              state.entries.reduce(0, { $0 + ($1.original?.count ?? 0) + $1.updated.count }) <= Self.maximumChangeBytes
        else { throw AskProjectError.tooLarge }
        for entry in state.entries {
            _ = try AskProjectFileAccess.parts(entry.path)
            _ = try AskProjectFileAccess.text(entry.updated)
            if let original = entry.original {
                _ = try AskProjectFileAccess.text(original)
            }
        }
        return state
    }

    private func save(_ state: AskProjectChangeSet, in directory: AskSecureDirectory) throws {
        let name = UUID().uuidString + ".json"
        defer { unlinkat(directory.descriptor, name, 0) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try directory.createFile(name, data: encoder.encode(state))
        guard renameat(directory.descriptor, name, directory.descriptor, "changes.json") == 0 else {
            throw AskSecureDirectory.failure("commit project changes")
        }
    }

    private func withWorkspace<T>(
        _ id: String,
        scope: AskProjectScope,
        authorizedRoots: [String],
        body: (inout AskProjectChangeSet, AskSecureDirectory, AskProjectFileAccess) throws -> T
    ) throws -> T {
        guard id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw AskProjectError.denied }
        let storage = try AskSecureDirectory.openRoot(storageURL, create: false)
        let directory = try storage.child(id, privateDirectory: true)
        try directory.lock()
        var state = try load(directory)
        try validate(state, id: id, scope: scope, authorizedRoots: authorizedRoots)
        let access = try source(state.root, authorizedRoots: authorizedRoots)
        let result = try body(&state, directory, access)
        try validate(state, id: id, scope: scope, authorizedRoots: authorizedRoots)
        return result
    }

    private func current(_ path: String, state: AskProjectChangeSet,
                         access: AskProjectFileAccess) throws -> AskProjectFileAccess.Snapshot {
        let source = try access.snapshot(path)
        guard let entry = state.entries.first(where: { $0.path == path }) else { return source }
        guard source.version == entry.sourceVersion else { throw AskProjectError.conflict }
        return .init(data: entry.updated, version: entry.version)
    }

    func binding(_ id: String, path: String?, scope: AskProjectScope,
                 authorizedRoots: [String]) throws -> AskExecutionTarget {
        try withWorkspace(id, scope: scope, authorizedRoots: authorizedRoots) { state, _, access in
            var version = state.workspace.version
            if let path, path != "." {
                // Bind current source evidence even when it conflicts with a
                // staged baseline; execution returns an actionable conflict result.
                try version += ":" + (access.snapshot(path).version)
                if let entry = state.entries.first(where: { $0.path == path }) {
                    version += ":" + entry.version
                }
            }
            return .init(kind: "workspace", id: id, version: version, path: state.root)
        }
    }

    func read(_ id: String, path: String, offset: Int = 0, limit: Int = 200,
              scope: AskProjectScope, authorizedRoots: [String]) throws -> AskProjectRead {
        try withWorkspace(id, scope: scope, authorizedRoots: authorizedRoots) { state, _, access in
            let snapshot = try current(path, state: state, access: access)
            let text = try snapshot.data.map(AskProjectFileAccess.text) ?? ""
            return AskProjectRead(workspace: state.workspace, path: path, version: snapshot.version,
                                  exists: snapshot.data != nil, text: text, offset: offset, limit: limit)
        }
    }

    func list(_ id: String, path: String, scope: AskProjectScope, authorizedRoots: [String]) throws -> [String] {
        try withWorkspace(id, scope: scope, authorizedRoots: authorizedRoots) { state, _, access in
            let prefix = path == "." ? "" : path + "/"
            let staged = state.entries.filter { $0.path.hasPrefix(prefix) }
                .map { String($0.path.dropFirst(prefix.count).split(separator: "/")[0]) }
            let entries: [String]
            do { entries = try access.list(path) } catch let error as NSError
                where !staged.isEmpty && error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                entries = []
            }
            return Array(Set(entries + staged)).sorted().prefix(501).map(\.self)
        }
    }

    // Keep the expected version, scope and live authorization explicit at this I/O boundary.
    // swiftlint:disable:next function_parameter_count
    func write(
        _ id: String,
        path: String,
        expectedVersion: String,
        content: String?,
        old: String? = nil,
        new: String? = nil,
        scope: AskProjectScope,
        authorizedRoots: [String]
    ) throws -> AskWorkspaceRef {
        try withWorkspace(id, scope: scope, authorizedRoots: authorizedRoots) { state, directory, access in
            // Reject aliases instead of exporting conflicting hunks for one macOS file.
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard !state.entries.contains(where: {
                $0.path != path && $0.path.precomposedStringWithCanonicalMapping.lowercased() == key
            }) else { throw AskProjectError.invalidPath }
            let snapshot = try current(path, state: state, access: access)
            guard snapshot.version == expectedVersion else { throw AskProjectError.conflict }
            let original = try snapshot.data.map(AskProjectFileAccess.text) ?? ""
            let updated: String
            if let content {
                updated = content
            } else {
                guard let old, !old.isEmpty, let new, original.components(separatedBy: old).count == 2 else {
                    throw AskProjectError.invalid
                }
                updated = original.replacingOccurrences(of: old, with: new)
            }
            guard updated.utf8.count <= AskFileTools.maximumWriteBytes, !updated.utf8.contains(0),
                  (snapshot.data?.count ?? 0) <= AskFileTools.maximumWriteBytes else { throw AskProjectError.tooLarge }
            let prior = state.entries.first { $0.path == path }
            let entry = AskProjectChangeSet.Entry(path: path, sourceVersion: prior?.sourceVersion ?? snapshot.version,
                                                  original: prior == nil ? snapshot.data : prior!.original,
                                                  updated: Data(updated.utf8))
            state.entries.removeAll { $0.path == path }
            if entry.original != entry.updated {
                state.entries.append(entry)
            }
            guard state.entries.count <= 100,
                  state.entries.reduce(0, { $0 + ($1.original?.count ?? 0) + $1.updated.count }) <= Self
                  .maximumChangeBytes else {
                throw AskProjectError.tooLarge
            }
            // Check again immediately before publishing the new manifest. Source
            // changes after this boundary are detected by the next read/review/export.
            guard try access.snapshot(path).version == entry.sourceVersion else { throw AskProjectError.conflict }
            try validate(state, id: id, scope: scope, authorizedRoots: authorizedRoots)
            state.workspace.version = UUID().uuidString.lowercased()
            try save(state, in: directory)
            return state.workspace
        }
    }

    func revert(_ id: String, expectedVersion: String, scope: AskProjectScope,
                authorizedRoots: [String]) throws -> AskWorkspaceRef {
        try withWorkspace(id, scope: scope, authorizedRoots: authorizedRoots) { state, directory, _ in
            guard state.workspace.version == expectedVersion else { throw AskProjectError.conflict }
            state.entries = []
            state.workspace.version = UUID().uuidString.lowercased()
            try save(state, in: directory)
            return state.workspace
        }
    }

    func review(_ id: String, scope: AskProjectScope, authorizedRoots: [String]) throws -> AskProjectReview {
        try withWorkspace(id, scope: scope, authorizedRoots: authorizedRoots) { state, _, access in
            for entry in state.entries {
                guard try access.snapshot(entry.path).version == entry.sourceVersion
                else { throw AskProjectError.conflict }
            }
            return AskProjectReview(changeSet: state)
        }
    }

    func export(_ ref: AskWorkspaceRef, scope: AskProjectScope, authorizedRoots: [String]) throws -> Data {
        try withValidatedSnapshot(ref, scope: scope, authorizedRoots: authorizedRoots) { state, _ in
            Data(state.patch.utf8)
        }
    }

    /// Host-only integration seam for D02/D03. The manifest is the edited view;
    /// The source root alone is NOT an executable working copy. Consumers must retain
    /// their own approval/containment and never pass these descriptors to a child.
    func withValidatedSnapshot<T>(_ ref: AskWorkspaceRef, scope: AskProjectScope, authorizedRoots: [String],
                                  body: (AskProjectChangeSet, AskProjectFileAccess) throws -> T) throws -> T {
        try withWorkspace(ref.id, scope: scope, authorizedRoots: authorizedRoots) { state, _, access in
            guard state.workspace == ref else { throw AskProjectError.conflict }
            for entry in state.entries {
                guard try access.snapshot(entry.path).version == entry.sourceVersion
                else { throw AskProjectError.conflict }
            }
            let result = try body(state, access)
            for entry in state.entries {
                guard try access.snapshot(entry.path).version == entry.sourceVersion
                else { throw AskProjectError.conflict }
            }
            return result
        }
    }
}

struct AskProjectRead: Codable {
    var workspace: AskWorkspaceRef
    var path: String
    var version: String
    var exists: Bool
    var text: String
    var totalLines: Int
    var nextOffset: Int?
    var truncatedLine = false

    init(
        workspace: AskWorkspaceRef,
        path: String,
        version: String,
        exists: Bool,
        text: String,
        offset: Int,
        limit: Int
    ) {
        self.workspace = workspace; self.path = path; self.version = version; self.exists = exists
        let lines = text.components(separatedBy: "\n")
        totalLines = lines.count
        let start = min(max(0, offset), lines.count)
        let end = start + min(lines.count - start, max(1, min(limit, 2000)))
        var output = "", next = start
        for index in start ..< end {
            let line = AskProjectFileAccess.preview(lines[index])
            if !output.isEmpty, output.utf8.count + line.utf8.count > 24000 {
                break
            }
            output += "\(index + 1)\t\(line)\n"
            next = index + 1
            if line != lines[index] {
                truncatedLine = true; break
            }
        }
        self.text = output
        nextOffset = next < lines.count ? next : nil
    }
}
