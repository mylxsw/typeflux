import Foundation

/// Space the clipboard history takes, per source app. Copied files are only referenced, so they
/// count as items but not as bytes.
struct ClipboardUsage: Equatable {
    struct App: Equatable, Identifiable {
        /// `nil` for items whose source app was not recorded.
        let bundleID: String?
        let name: String?
        let itemCount: Int
        let bytes: Int64

        var id: String { bundleID ?? "" }
    }

    let apps: [App]

    var totalBytes: Int64 { apps.reduce(0) { $0 + $1.bytes } }
    var totalCount: Int { apps.reduce(0) { $0 + $1.itemCount } }

    /// Groups items by source app, largest first.
    init(items: [ClipboardItem]) {
        let groups = Dictionary(grouping: items) { $0.sourceBundleID.flatMap { $0.isEmpty ? nil : $0 } }
        apps = groups.map { bundleID, items in
            App(
                bundleID: bundleID,
                name: items.lazy.compactMap(\.sourceAppName).first,
                itemCount: items.count,
                bytes: items.reduce(0) { $0 + ($1.payload == .files ? 0 : $1.byteSize) }
            )
        }
        .sorted { lhs, rhs in
            lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : (lhs.name ?? "") < (rhs.name ?? "")
        }
    }
}

extension ClipboardHistoryStore {
    /// Every stored item grouped by app; trimming keeps the item count small.
    func usage() -> ClipboardUsage {
        ClipboardUsage(items: items(limit: Int(Int32.max)))
    }
}

/// An app whose copies are never recorded.
struct ClipboardIgnoredApp: Codable, Equatable, Identifiable {
    let bundleID: String
    let name: String

    var id: String { bundleID }

    /// Apps that handle passwords; 1Password and other password managers already mark their copies
    /// as concealed, which is always respected.
    static let defaults = [
        ClipboardIgnoredApp(bundleID: "com.apple.keychainaccess", name: "Keychain Access"),
        ClipboardIgnoredApp(bundleID: "com.apple.Passwords", name: "Passwords")
    ]

    /// Reads an app bundle chosen in an open panel.
    init?(appURL: URL) {
        guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else {
            return nil
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        self.init(bundleID: bundleID, name: name)
    }

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}
