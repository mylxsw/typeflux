import AppKit
import CryptoKit
import Foundation

struct RecentInputMemoryScope: Equatable {
    let appIdentifier: String
    let key: String

    static func resolve(bundleIdentifier: String?) -> RecentInputMemoryScope? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
            .contains(bundleIdentifier.lowercased()) {
            return nil
        }
        if let browser = AXTextInjector.browserAutomationKind(for: bundleIdentifier) {
            guard let url = browserURL(bundleIdentifier: browser.bundleIdentifier, command: browser.command),
                  let scope = browserScope(bundleIdentifier: bundleIdentifier, url: url)
            else { return nil }
            return scope
        }
        return RecentInputMemoryScope(appIdentifier: bundleIdentifier, key: bundleIdentifier)
    }

    static func browserScope(bundleIdentifier: String, url: URL) -> RecentInputMemoryScope? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              ["https", "http"].contains(components.scheme?.lowercased() ?? "")
        else { return nil }
        let pageIdentity = (components.path.isEmpty ? "/" : components.path)
            + (components.query.map { "?\($0)" } ?? "")
        let origin = "\(components.scheme?.lowercased() ?? "https")://\(host):\(components.port ?? 0)"
        let digest = SHA256.hash(data: Data((origin + pageIdentity).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return RecentInputMemoryScope(appIdentifier: bundleIdentifier, key: "\(bundleIdentifier)|\(digest)")
    }

    private static func browserURL(
        bundleIdentifier: String,
        command: AXTextInjector.BrowserAutomationKind.Command
    ) -> URL? {
        let quotedIdentifier = AXTextInjector.appleScriptQuotedString(bundleIdentifier)
        let script = switch command {
        case .chromium:
            "tell application id \(quotedIdentifier) to get URL of active tab of front window"
        case .safari:
            "tell application id \(quotedIdentifier) to get URL of front document"
        }
        var error: NSDictionary?
        guard let value = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil,
              let address = value.stringValue else { return nil }
        return URL(string: address)
    }
}
