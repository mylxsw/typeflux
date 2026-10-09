import Darwin
import Foundation

/// MNT_NOWAIT reads cached kernel mount information without entering a remote/FUSE mount.
/// Calling statfs(path) first would itself traverse the potentially blocked mount.
struct AskFileMounts {
    var excluded: [String]

    static func current() -> AskFileMounts {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count >= 0 else { return AskFileMounts(excluded: ["/"]) }
        var records: [statfs] = .init(repeating: .init(), count: Int(count) + 16)
        let capacity = Int32(records.count * MemoryLayout<statfs>.stride)
        let found = records.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, capacity, MNT_NOWAIT) }
        guard found >= 0 else { return AskFileMounts(excluded: ["/"]) }
        let excluded = records.prefix(Int(found)).compactMap { record -> String? in
            var record = record
            let type = withUnsafeBytes(of: &record.f_fstypename) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard shouldSkip(type: type, flags: record.f_flags) else { return nil }
            return withUnsafeBytes(of: &record.f_mntonname) { bytes in
                AskFileScope.normalize(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
            }
        }
        return AskFileMounts(excluded: excluded)
    }

    static func shouldSkip(type: String, flags: UInt32) -> Bool {
        let type = type.lowercased()
        return flags & UInt32(MNT_LOCAL) == 0 || type.contains("fuse") || ["autofs", "virtiofs"].contains(type)
    }

    func blocking(_ path: String) -> String? {
        excluded.first { AskFileScope.isProtected(Self.dataAlias(path), folders: [Self.dataAlias($0)]) }
    }

    private static func dataAlias(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
    }
}
