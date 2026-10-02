@testable import Typeflux

/// In-memory clipboard shared by workflow and Ask tests.
final class MockClipboardService: ClipboardService, @unchecked Sendable {
    var storedText: String?

    func write(text: String) {
        storedText = text
    }

    func getString() -> String? {
        storedText
    }
}
