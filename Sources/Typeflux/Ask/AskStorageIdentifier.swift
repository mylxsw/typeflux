import Foundation

/// Plain identifiers shared by the fixed-directory persistence stores.
enum AskStorageIdentifier {
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id
            .allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }
}
