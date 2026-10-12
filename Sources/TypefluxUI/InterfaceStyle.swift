import Foundation

/// Persisted under `ui.overlayStyle` by the host application. Keep raw values stable.
public enum InterfaceStyle: String, CaseIterable, Codable, Sendable {
    case liquidGlass
    case classic

    public var usesGlass: Bool {
        self == .liquidGlass
    }
}
