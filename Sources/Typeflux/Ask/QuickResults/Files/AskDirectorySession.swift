import Darwin
import Foundation

struct AskDirectoryCursor: Codable, Equatable, Sendable {
    var session = ""
    var version = ""
    var inspected: Int64 = 0
}

/// Owns one bounded directory stream in the disposable worker. Never persist/reuse a telldir cookie
/// against a different DIR. After worker loss, replay that directory; committed child/file work survives.
final class AskDirectorySession {
    private var directory: AskDirectoryIterator?
    private var path = ""
    private var scope: AskFileScope?
    private var cursor = AskDirectoryCursor()

    deinit { close() }

    private func close() {
        directory = nil
    }

    // Keep resource ownership, cancellation and state checks in one operation.
    // swiftlint:disable:next cyclomatic_complexity
    func page(_ request: AskFileReadRequest, scope: AskFileScope, mounts: AskFileMounts) -> AskFileReadResponse {
        let descriptor = AskFileWorkerCommand.openDirectory(request.path, blocked: scope.blocked + mounts.excluded)
        guard descriptor >= 0 else { close(); return .init(error: errno) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno; Darwin.close(descriptor); close(); return .init(error: code)
        }
        let version = AskFileWorkerCommand.contentVersion(metadata)
        if directory != nil, path == request.path, self.scope == scope,
           cursor == request.directoryCursor, cursor.version == version {
            Darwin.close(descriptor)
        } else {
            close()
            do {
                directory = try AskDirectoryIterator(descriptor: descriptor, reopen: {
                    AskFileWorkerCommand.openDirectory(request.path, blocked: scope.blocked + mounts.excluded)
                })
            } catch { return .init(error: Int32((error as NSError).code)) }
            path = request.path; self.scope = scope
            cursor = .init(session: UUID().uuidString, version: version)
        }
        guard let directory else { return .init(error: EIO) }
        var response = AskFileReadResponse(inspected: 0)
        // Count filtered names too: a directory containing millions of ignored files still yields.
        for _ in 0 ..< 128 {
            let item: AskDirectoryIterator.Item
            do {
                guard let next = try directory.next() else { close(); return response }
                item = next
            } catch {
                response.error = Int32((error as NSError).code); close(); return response
            }
            cursor.inspected += 1; response.inspected? += 1
            let name = item.name
            guard name != ".", name != ".." else { continue }
            let child = (path == "/" ? "" : path) + "/" + name
            guard scope.includes(child, isDirectory: item.isDirectory) else { continue }
            if let mount = mounts.blocking(child) {
                response.skippedMounts = (response.skippedMounts ?? []) + [mount]; continue
            }
            if let entry = item.entry(parent: directory.descriptor, path: child, scope: scope) {
                response.entries.append(entry)
            }
        }
        response.directoryCursor = cursor
        return response
    }
}
