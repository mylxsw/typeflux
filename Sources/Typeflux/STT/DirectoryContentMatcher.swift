import CryptoKit
import Foundation

private struct DirectoryFileFingerprint: Equatable {
    let size: UInt64
    let sha256: String?
}

enum DirectoryContentMatcher {
    /// Large model blobs can be hundreds of MB. Size checks catch most changes there,
    /// while hashing smaller control/runtime files catches same-size replacements.
    private static let maxHashedFileSize: UInt64 = 64 * 1024 * 1024

    static func contentsMatch(
        sourceURL: URL,
        targetURL: URL,
        fileManager: FileManager,
    ) -> Bool {
        guard let sourceFiles = fingerprints(under: sourceURL, fileManager: fileManager),
              let targetFiles = fingerprints(under: targetURL, fileManager: fileManager)
        else {
            return false
        }
        return sourceFiles == targetFiles
    }

    private static func fingerprints(
        under rootURL: URL,
        fileManager: FileManager,
    ) -> [String: DirectoryFileFingerprint]? {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
        ) else {
            return nil
        }

        var result: [String: DirectoryFileFingerprint] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isDirectory == true || values?.isSymbolicLink == true {
                continue
            }

            let size = UInt64(values?.fileSize ?? 0)
            let relativePath = String(url.path.dropFirst(rootURL.path.count + 1))
            result[relativePath] = DirectoryFileFingerprint(
                size: size,
                sha256: size <= maxHashedFileSize ? sha256Digest(of: url) : nil,
            )
        }
        return result
    }

    private static func sha256Digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
