import Foundation

/// Shared storage failures contain no SQL, paths or user content. A failed write
/// may have committed before its response was lost; callers must not replay it.
enum LocalStoreFailure: Error, Sendable, Equatable {
    case unavailable, busy, invalidData
}
