import Foundation

/// Two equally sized RGBA frames, concatenated in the private input file.
public struct MediaRegistrationInput: Codable, Sendable {
    public static let pairBytes = 128 * 1024 * 1024
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var frameBytes: Int { width * height * 4 }
    public func validate() throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width <= 16_000_000 / height else { throw MediaFailure.tooLarge }
    }
}

public struct MediaRegistration: Codable, Sendable {
    public var translationY: Double?
    public init(translationY: Double?) { self.translationY = translationY }
    public func validate(for input: MediaRegistrationInput) throws {
        try input.validate()
        if let translationY {
            guard translationY.isFinite, abs(translationY) <= Double(input.height)
            else { throw MediaFailure.invalidProtocol }
        }
    }
}
