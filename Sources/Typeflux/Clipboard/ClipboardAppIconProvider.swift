import AppKit

/// Resolves the icon of the app a clipboard entry was copied from.
///
/// Lookups go through Launch Services, so results are cached per bundle ID, including misses:
/// an uninstalled app is not looked up again on every redraw.
final class ClipboardAppIconProvider {
    static let shared = ClipboardAppIconProvider()

    private let applicationURL: (String) -> URL?
    private let iconForApplication: (URL) -> NSImage?
    private let ownIcon: () -> NSImage?
    private let lock = NSLock()
    private var cache: [String: NSImage?] = [:]

    init(
        applicationURL: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        iconForApplication: @escaping (URL) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0.path) },
        ownIcon: @escaping () -> NSImage? = { NSApplication.shared.applicationIconImage }
    ) {
        self.applicationURL = applicationURL
        self.iconForApplication = iconForApplication
        self.ownIcon = ownIcon
    }

    /// Voice results come from Typeflux itself; copied content from its recorded source app.
    /// `nil` when the source is unknown or no longer installed.
    func icon(for entry: ClipboardEntry) -> NSImage? {
        if entry.kind == .voice { return ownIcon() }
        return icon(forBundleID: entry.sourceBundleID)
    }

    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        lock.lock()
        if let cached = cache[bundleID] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let icon = applicationURL(bundleID).flatMap(iconForApplication)
        lock.lock()
        cache[bundleID] = .some(icon)
        lock.unlock()
        return icon
    }
}
