import Darwin
import Foundation

extension AskFileTools {
    /// One process-wide gate also covers aliases/overlapping grants for the same target.
    /// NSFileCoordinator supplies cooperation with editors outside Typeflux.
    private static let mutationLock = NSLock()

    func mutate(_ path: String, expectedVersion: String?, content: String?,
                replacement: (String, String)?) throws -> String {
        try Task.checkCancellation()
        let inputs = [content, replacement?.0, replacement?.1].compactMap(\.self)
        guard inputs.allSatisfy({ $0.utf8.count <= Self.maximumWriteBytes }) else {
            throw AskFileAccess.error(L("ask.files.tooLarge"))
        }
        guard inputs.allSatisfy({ !$0.utf8.contains(0) }) else { throw AskFileAccess.error(L("ask.files.binary")) }
        guard replacement?.0.isEmpty != true else { throw AskFileAccess.error(L("ask.tool.invalid")) }
        let location = try AskFileAccess.location(path, roots: roots)
        guard !location.parts.isEmpty else { throw AskFileAccess.denied }
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<String, Error>?
        coordinator.coordinate(
            writingItemAt: URL(fileURLWithPath: location.path),
            options: .forReplacing,
            error: &coordinationError
        ) { _ in
            result = Result {
                try Task.checkCancellation()
                let access = try AskFileAccess(
                    location,
                    createParents: content != nil,
                    allowMissing: content != nil,
                    hooks: hooks
                )
                guard access.initial?.st_nlink ?? 1 == 1 else { throw AskFileAccess.denied }
                if access.initial != nil {
                    guard let expectedVersion
                    else {
                        throw AskFileAccess
                            .error("Read the file first and supply expected_version before changing an existing file.")
                    }
                    guard expectedVersion == access.version else { throw AskFileAccess.conflict }
                } else if expectedVersion != nil {
                    throw AskFileAccess.conflict
                }
                let original = access.initial == nil ? nil : try access.boundedData(limit: Self.maximumEditBytes)
                let originalDigest = original.map(AskFileAccess.digest)
                try hooks.onEvent?("prepared")
                let output = try Self.mutationOutput(original: original, content: content, replacement: replacement)
                try Task.checkCancellation()
                let temporary = ".typeflux-write-" + UUID().uuidString
                let staging = openat(
                    access.parent.descriptor,
                    temporary,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                guard staging >= 0 else { throw AskFileAccess.denied }
                var staged = true
                defer {
                    close(staging)
                    if staged {
                        unlinkat(access.parent.descriptor, temporary, 0)
                    }
                }
                try writeStaging(staging, output: output)
                let mode = access.initial.map { $0.st_mode & 0o777 } ?? 0o600
                guard fchmod(staging, mode) == 0, fsync(staging) == 0 else { throw AskFileAccess.denied }
                let stagingStamp = try AskFileAccess.stamp(AskFileAccess.info(staging))
                try hooks.onEvent?("staged")
                try hooks.onEvent?("precommit")
                if let originalDigest {
                    let current = try access.boundedData(limit: Self.maximumEditBytes)
                    guard AskFileAccess.digest(current) == originalDigest else { throw AskFileAccess.conflict }
                }
                try access.revalidate()
                var stagedLink = stat()
                guard fstatat(access.parent.descriptor, temporary, &stagedLink, AT_SYMLINK_NOFOLLOW) == 0,
                      AskFileAccess.stamp(stagedLink) == stagingStamp,
                      try AskFileAccess.stamp(AskFileAccess.info(staging)) == stagingStamp else {
                    throw AskFileAccess.conflict
                }
                // Cancellation observed here leaves the destination unchanged. After
                // commit, return its receipt even if cancellation arrives concurrently.
                try hooks.onEvent?("commit")
                try Task.checkCancellation()
                let status = access.initial == nil
                    ? renameatx_np(
                        access.parent.descriptor,
                        temporary,
                        access.parent.descriptor,
                        access.name,
                        UInt32(RENAME_EXCL)
                    )
                    : renameat(access.parent.descriptor, temporary, access.parent.descriptor, access.name)
                guard status == 0 else { throw AskFileAccess.conflict }
                staged = false
                hooks.onCommit?()
                // No throwing postcommit hooks or checks: a successful effect must not
                // be reported as cancelled and then automatically replayed.
                return replacement != nil ? "Edited \(location.path)." : "\(access.initial == nil ? "Created" : "Replaced") \(location.path) (\(output.count) bytes)."
            }
        }
        if let result {
            return try result.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw AskFileAccess.denied
    }

    private static func mutationOutput(original: Data?, content: String?,
                                       replacement: (String, String)?) throws -> Data {
        if let content {
            return Data(content.utf8)
        }
        guard let replacement, let original else { throw AskFileAccess.denied }
        _ = try AskProjectFileAccess.text(original)
        let old = Data(replacement.0.utf8)
        guard let first = original.range(of: old) else { throw AskFileAccess.error(L("ask.files.editMissing")) }
        guard original.range(of: old, in: first.upperBound ..< original.endIndex) == nil else {
            throw AskFileAccess.error("Found at least 2 matches. Supply a unique old_text snippet.")
        }
        let size = original.count - old.count + replacement.1.utf8.count
        guard size <= Self.maximumWriteBytes else { throw AskFileAccess.error(L("ask.files.tooLarge")) }
        var updated = original
        updated.replaceSubrange(first, with: replacement.1.utf8)
        return updated
    }

    private func writeStaging(_ staging: Int32, output: Data) throws {
        try output.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                try Task.checkCancellation()
                try hooks.onEvent?("write")
                let count = Darwin.write(
                    staging,
                    bytes.baseAddress!.advanced(by: position),
                    min(65536, bytes.count - position)
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0
                else { throw AskFileAccess.error("Could not write the file. Check free space and folder access.") }
                position += count
            }
        }
    }
}
