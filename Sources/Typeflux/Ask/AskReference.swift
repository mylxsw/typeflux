import Foundation

struct AskReference: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var messageId: String
    var text: String
    var question = ""
}
