import Foundation

/// The parts of `sys`, in sidebar order: ⌘1…⌘8 follow it.
enum SystemInfoSection: String, CaseIterable, Sendable {
    case overview, processor, memory, storage, display, network, battery, system

    var title: String {
        L("system.info.section.\(rawValue)")
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .processor: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .display: "display"
        case .network: "network"
        case .battery: "battery.75percent"
        case .system: "gearshape"
        }
    }
}

/// A word the value is drawn with: "On", "Supported", "Off".
enum SystemInfoBadge: Equatable, Sendable {
    case good, warning, off
}

/// One line of the configuration: a label, its value and what explains it.
struct SystemInfoField: Identifiable, Equatable, Sendable {
    /// Stable across reads, so a chosen row stays chosen when the values refresh.
    var id: String
    var section: SystemInfoSection
    /// The device or topic the row belongs to: "Internal · Macintosh HD", "Wi-Fi (en0)".
    var group: String
    var label: String
    var value: String
    var detail: String?
    /// Serial numbers, hardware addresses and the host name are hidden until asked for,
    /// left out of reports, and not searched by value while hidden.
    var sensitive = false
    var badge: SystemInfoBadge?
    /// 0...1 for a capacity or charge bar.
    var fraction: Double?
    /// Words people search with besides the label, in English and Chinese: "ip", "序列号".
    var keywords: [String] = []

    /// What a copy or a report writes: the value with its detail.
    var text: String {
        guard let detail, !detail.isEmpty else { return value }
        return value + " (" + detail + ")"
    }
}

/// One card on the overview: a section's headline value.
struct SystemInfoCard: Equatable, Sendable {
    var section: SystemInfoSection
    var value: String
    var detail: String
    var fraction: Double?
}

/// Everything `sys` shows, built once per read.
struct SystemInfoSnapshot: Equatable, Sendable {
    /// "Mac mini (2023)", or the model identifier when macOS does not name it.
    var title: String
    /// "Mac14,12 · Apple M2 Pro".
    var subtitle: String
    /// "macOS Sequoia 15.1 (24B83)".
    var system: String
    var cards: [SystemInfoCard]
    var fields: [SystemInfoField]
    var hasBattery: Bool

    /// The sidebar: a Mac without a battery has no battery section.
    var sections: [SystemInfoSection] {
        SystemInfoSection.allCases.filter { $0 != .battery || hasBattery }
    }

    func fields(in section: SystemInfoSection) -> [SystemInfoField] {
        fields.filter { $0.section == section }
    }

    func field(_ id: String) -> SystemInfoField? {
        fields.first { $0.id == id }
    }
}

/// Finds fields by what people type. Latin words match the start of a word in the label,
/// group, section or value ("ip" finds "IPv4" but not "Chip"); Chinese, Japanese and Korean
/// text matches anywhere, as it has no spaces between words.
enum SystemInfoSearch {
    /// What splits text into words; dots and colons stay, so "192.168" finds an address.
    private static let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",·()/–-+×"))

    static func matches(_ field: SystemInfoField, query: String, valueVisible: Bool) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let text = [field.label, field.group, field.section.title, valueVisible ? field.value : "",
                    valueVisible ? field.detail ?? "" : ""].joined(separator: " ").lowercased()
        let tokens = text.components(separatedBy: separators).filter { !$0.isEmpty }
        let keywords = field.keywords.map { $0.lowercased() }
        return words.allSatisfy { word in
            if keywords.contains(where: { $0.hasPrefix(word) }) {
                return true
            }
            if word.unicodeScalars.contains(where: { !$0.isASCII }) {
                return text.contains(word)
            }
            return tokens.contains { $0.hasPrefix(word) }
        }
    }

    /// Matching fields in the order they are listed. Hidden values are not searched,
    /// so typing a serial number does not reveal which row holds it.
    static func filter(_ fields: [SystemInfoField], query: String,
                       revealed: Set<String> = []) -> [SystemInfoField] {
        fields.filter { matches($0, query: query, valueVisible: !$0.sensitive || revealed.contains($0.id)) }
    }
}

/// The configuration as text for issues and messages.
enum SystemInfoReport {
    /// "Mac mini (2023) · Apple M2 Pro · 32 GB · 1 TB · macOS Sequoia 15.1 (24B83)".
    static func summary(_ snapshot: SystemInfoSnapshot) -> String {
        var parts = [snapshot.title]
        for section in [SystemInfoSection.processor, .memory, .storage] {
            if let card = snapshot.cards.first(where: { $0.section == section }) {
                parts.append(card.value)
            }
        }
        parts.append(snapshot.system)
        return parts.joined(separator: " · ")
    }

    /// Markdown by section, without sensitive values unless asked for.
    static func markdown(_ snapshot: SystemInfoSnapshot, includeSensitive: Bool = false) -> String {
        var lines = ["## " + snapshot.title, "", snapshot.subtitle + " · " + snapshot.system]
        for section in snapshot.sections where section != .overview {
            let fields = snapshot.fields(in: section).filter { includeSensitive || !$0.sensitive }
            guard !fields.isEmpty else { continue }
            lines += ["", "### " + section.title]
            var group: String?
            for field in fields {
                if field.group != group, !field.group.isEmpty, field.group != section.title {
                    lines.append("- **" + field.group + "**")
                    group = field.group
                }
                let indent = group == nil ? "" : "  "
                lines.append(indent + "- " + field.label + ": " + field.text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
