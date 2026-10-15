import Foundation

/// Reuse the metadata helper across queries without sharing the indexing reader or its stream.
final class SemanticFileValidator: @unchecked Sendable {
    private let lock = NSLock()
    private let reader: any AskFileReading

    init(reader: any AskFileReading) { self.reader = reader }

    func warm(scope: AskFileScope, cancelled: () -> Bool) throws {
        try lock.withLock {
            guard let root = scope.roots.first, !cancelled() else { return }
            _ = try reader.read(.init(operation: .resolve, path: root, blocked: scope.blocked), isCancelled: cancelled)
        }
    }

    func validate(_ hits: [AskFileHit], scope: AskFileScope, limit: Int, cancelled: () -> Bool) -> [AskFileHit] {
        let waiting = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            SemanticSearchTrace.current?.measure("metadata-lock-wait",
                milliseconds: (ProcessInfo.processInfo.systemUptime - waiting) * 1000)
            var valid: [AskFileHit] = []
            for hit in hits {
                guard !cancelled() else { break }
                guard let response = try? reader.read(.init(operation: .content, path: hit.path,
                                                           scope: scope, readText: false), isCancelled: cancelled),
                      response.error == nil, response.modified == hit.modified,
                      hit.evidence?.version == nil || hit.evidence?.version == response.version else { continue }
                valid.append(hit)
                if valid.count >= limit { break }
            }
            return valid
        }
    }
}
