import Darwin
import Foundation

/// Private atomic JSON storage for the macOS execution host. Foundation's
/// completeFileProtection write option can fail with EPERM on this host.
/// Stage in an owner-only directory and publish a 0600 file with one rename;
/// never expose a partially written snapshot or relax directory permissions.
enum AskPrivateFile {
    static func write(_ data: Data, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("snapshot")
        try data.write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
