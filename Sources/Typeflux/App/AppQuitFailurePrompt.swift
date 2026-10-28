import AppKit

@MainActor
enum AppQuitFailurePrompt {
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("feature.quitBlocked.title")
        alert.informativeText = L("feature.quitBlocked.message")
        alert.addButton(withTitle: L("feature.quitBlocked.keepOpen"))
        alert.addButton(withTitle: L("feature.quitBlocked.retry"))
        alert.addButton(withTitle: L("feature.quitBlocked.force"))
        return alert
    }
}
