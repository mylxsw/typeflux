import Foundation
import SwiftUI

/// The app-wide visual language chosen in Settings › Interface style. It decides
/// how the recording capsule, the launcher, the chat window, the clipboard panel
/// and their menus are drawn: Liquid Glass, or the flat opaque surfaces macOS
/// used before it. Stored under `ui.overlayStyle`, its name from when it only
/// styled the capsule, so existing choices carry over.
enum InterfaceStyle: String, CaseIterable, Codable {
    case liquidGlass
    case classic

    var displayName: String {
        switch self {
        case .liquidGlass:
            L("interfaceStyle.liquidGlass")
        case .classic:
            L("interfaceStyle.classic")
        }
    }

    /// Whether surfaces may be translucent glass. Classic draws every surface opaque.
    var usesGlass: Bool { self == .liquidGlass }
}

extension EnvironmentValues {
    @Entry var interfaceStyle: InterfaceStyle = .liquidGlass
}

/// Publishes the stored interface style and follows changes made in Settings,
/// so open windows restyle at once instead of on their next launch.
@MainActor
final class InterfaceStyleObserver: ObservableObject {
    @Published private(set) var style: InterfaceStyle
    private let settings: SettingsStore
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(settings: SettingsStore, center: NotificationCenter = .default) {
        self.settings = settings
        self.center = center
        style = settings.interfaceStyle
        // Any store may post: they all write the same defaults.
        token = center.addObserver(forName: .interfaceStyleDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    func refresh() {
        let next = settings.interfaceStyle
        if next != style { style = next }
    }
}

/// Hands a root view the observed interface style through the environment.
struct InterfaceStyleRoot: ViewModifier {
    @ObservedObject var observer: InterfaceStyleObserver

    func body(content: Content) -> some View {
        content.environment(\.interfaceStyle, observer.style)
    }
}

extension View {
    /// Styles this window's content with the interface style `observer` follows.
    func interfaceStyle(following observer: InterfaceStyleObserver) -> some View {
        modifier(InterfaceStyleRoot(observer: observer))
    }
}
