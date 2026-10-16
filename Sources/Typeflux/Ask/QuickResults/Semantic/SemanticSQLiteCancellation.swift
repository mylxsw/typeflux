import Foundation
import SQLite3

/// Readers own their connection lock. Poll cancellation inside SQLite sorting/scanning, including
/// the work before the first row. The callback is removed before the caller rolls back its read transaction.
enum SemanticSQLiteCancellation {
    private static func installBackground(_ database: OpaquePointer) {
        sqlite3_progress_handler(database, 1000, { _ in
            let cancelled = { SemanticWorkBudget.cancellation?() ?? false }
            if cancelled() {
                return 1
            }
            _ = try? SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
            return cancelled() ? 1 : 0
        }, nil)
    }

    static func read<Value>(_ database: OpaquePointer, cancelled: () -> Bool, background: Bool = false,
                            operation: () throws -> Value) throws -> Value {
        guard !cancelled() else { throw CancellationError() }
        return try withoutActuallyEscaping(cancelled) { check in
            var predicate = {
                if check() {
                    return true
                }
                // SQLite invokes this on the owning thread; no connection or model is touched while yielding.
                _ = try? SemanticWorkBudget.current?.checkpoint(cancelled: check)
                return check()
            }
            return try withUnsafeMutablePointer(to: &predicate) { pointer in
                sqlite3_progress_handler(database, 1000, { context in
                    guard let context else { return 0 }
                    return context.assumingMemoryBound(to: (() -> Bool).self).pointee() ? 1 : 0
                }, UnsafeMutableRawPointer(pointer))
                defer {
                    if background {
                        installBackground(database)
                    } else {
                        sqlite3_progress_handler(database, 0, nil, nil)
                    }
                }
                do {
                    let value = try operation()
                    guard !check() else { throw CancellationError() }
                    return value
                } catch {
                    if check() {
                        throw CancellationError()
                    }
                    throw error
                }
            }
        }
    }
}
