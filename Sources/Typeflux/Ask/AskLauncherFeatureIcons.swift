import AppKit

/// Both families ship together; switching this preference needs no asset replacement or rebuild.
@MainActor
enum AskLauncherFeatureIcons {
    enum Style: String, CaseIterable {
        case sculpted
        case light
    }

    static let preferenceKey = "launcherFeatureIconStyle"
    static let names = ["chat", "translate", "screenshot", "recording", "notes", "wordbook", "clipboard", "settings"]
    private static var cache: [String: NSImage] = [:]

    static func image(for rowID: String, style: Style) -> NSImage? {
        let name = rowID.hasPrefix("feature.") ? String(rowID.dropFirst("feature.".count)) : rowID
        guard names.contains(name) else { return nil }
        let resource = "launcher-feature-" + style.rawValue + "-" + name
        if let cached = cache[resource] { return cached }
        guard let url = Bundle.module.url(forResource: resource, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[resource] = image
        return image
    }
}
