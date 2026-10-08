import Foundation

/// A presentation decision, independent of AppKit/UIKit and the model's routing protocol.
public enum ModelIconDescriptor: Equatable, Sendable {
    case asset(String, monochrome: Bool)
    case provider
    case generic

    public var resourceKey: String? {
        if case let .asset(key, _) = self {
            return key
        }
        return nil
    }

    public var isMonochrome: Bool {
        if case let .asset(_, monochrome) = self {
            return monochrome
        }
        return false
    }

    public func resourceURL(dark: Bool) -> URL? {
        guard let key = resourceKey,
              key.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return ModelIconResources.bundle.url(forResource: key + (dark ? "-dark" : "-light"),
                                             withExtension: "png", subdirectory: "ModelIcons")
    }
}

public enum ModelIconResolver {
    struct Catalog: Decodable {
        var icons: [Icon]
    }

    struct Icon: Decodable {
        var key: String
        var monochrome: Bool
        var descriptor: ModelIconDescriptor {
            .asset(key, monochrome: monochrome)
        }
    }

    struct Rules: Decodable {
        var exact: [String: String]
        var aliases: [String: [String]]
        var providers: [String: String]
    }

    static let catalog: [Icon] = decode("catalog", as: Catalog.self)?.icons ?? []
    static let rules = decode("rules", as: Rules.self) ?? Rules(exact: [:], aliases: [:], providers: [:])
    private static let byKey = Dictionary(uniqueKeysWithValues: catalog.map { ($0.key, $0.descriptor) })
    /// Compile once. Families match token boundaries, allowing attached version digits (qwen3).
    private static let patterns: [(icon: ModelIconDescriptor, regex: NSRegularExpression)] = catalog
        .compactMap { icon in
            let aliases = [NSRegularExpression.escapedPattern(for: icon.key)] + (rules.aliases[icon.key] ?? [])
            let pattern = "(?:^|[^a-z0-9])(" + aliases.joined(separator: "|") + ")(?=$|[^a-z])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (icon.descriptor, regex)
        }

    public static func resolve(modelID: String, displayName: String = "",
                               providerID: String? = nil) -> ModelIconDescriptor {
        let identifier = normalize(modelID)
        // Routing aliases do not describe a model, even when a provider or label is present.
        if ["default", "auto"].contains(identifier) {
            return .generic
        }
        if let key = rules.exact[identifier], let icon = byKey[key] {
            return icon
        }
        // An owner namespace must not override a more specific family in the leaf name.
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let leaf = parts.last?.split(separator: ":").first,
           let key = rules.exact[String(leaf)], let icon = byKey[key] {
            return icon
        }
        if let icon = match(parts.last ?? identifier) {
            return icon
        }
        if let icon = match(normalize(displayName)) {
            return icon
        }
        for namespace in parts.dropLast().reversed() {
            if let icon = match(namespace) {
                return icon
            }
        }
        if let providerID, !normalize(providerID).isEmpty {
            if let key = rules.providers[normalize(providerID)], let icon = byKey[key] {
                return icon
            }
            return .provider
        }
        return .generic
    }

    private static func match(_ value: String) -> ModelIconDescriptor? {
        // Earliest family wins for derivative names: DeepSeek-R1-Distill-Qwen stays DeepSeek.
        // At the same position a longer, more specific family wins (command-a before command).
        let range = NSRange(value.startIndex..., in: value)
        var best: (icon: ModelIconDescriptor, range: NSRange)?
        for pattern in patterns {
            guard let result = pattern.regex.firstMatch(in: value, range: range) else { continue }
            let candidate = result.range(at: 1)
            if best == nil || candidate.location < best!.range.location
                || (candidate.location == best!.range.location && candidate.length > best!.range.length) {
                best = (pattern.icon, candidate)
            }
        }
        return best?.icon
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decode<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let url = ModelIconResources.bundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "ModelIcons"
        ),
            let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum ModelIconResources {
    /// Older SwiftPM accessors omit Contents/Resources in manually assembled macOS apps.
    static let bundle = installedBundle(in: Bundle.main.resourceURL) ?? Bundle.module

    static func installedBundle(in resourceURL: URL?) -> Bundle? {
        guard let resourceURL else { return nil }
        return Bundle(url: resourceURL.appendingPathComponent("TypefluxChat_TypefluxChat.bundle"))
    }
}
