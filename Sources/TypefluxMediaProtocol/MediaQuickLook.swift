import Foundation

/// Original file context is required by native Quick Look providers. No URL/network operations.
public struct MediaQuickLook: Codable, Sendable, Equatable {
    public enum Representation: String, Codable, Sendable { case all, thumbnail }
    public static let maximumBytes: Int64 = 512 * 1024 * 1024
    public static let maximumEntries = 4096
    public var path: String
    public var representation: Representation
    public init(path: String, representation: Representation) { self.path = path; self.representation = representation }
    public func validate() throws {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw MediaFailure.invalidProtocol }
    }
}
