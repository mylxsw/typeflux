import AppKit
import Foundation

/// A mock implementation of an auto-updater.
/// To be replaced with a real API later.
enum AutoUpdater {
    static func checkForUpdates(manual: Bool = true) {
        // Simulating a network request
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            let hasUpdate = true // Mock data: always has update for now
            let mockVersion = "2.0.0"
            let mockReleaseNotes = """
            - Added new awesome feature
            - Fixed several bugs
            """

            DispatchQueue.main.async {
                if hasUpdate {
                    let alert = NSAlert()
                    alert.messageText = L("updater.available.title")
                    alert.informativeText = L("updater.available.message", mockVersion, mockReleaseNotes)
                    alert.addButton(withTitle: L("updater.action.download"))
                    alert.addButton(withTitle: L("updater.action.later"))

                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        // Open mock download URL
                        if let url = URL(string: "https://example.com/update") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else if manual {
                    let alert = NSAlert()
                    alert.messageText = L("updater.latest.title")
                    alert.informativeText = L("updater.latest.message")
                    alert.addButton(withTitle: L("common.ok"))
                    alert.runModal()
                }
            }
        }
    }
}
