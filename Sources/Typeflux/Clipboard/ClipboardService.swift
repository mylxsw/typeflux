import AppKit
import Foundation

protocol ClipboardService: Sendable {
    func write(text: String)
    func getString() -> String?
}

final class SystemClipboardService: ClipboardService {
    func write(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func getString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
