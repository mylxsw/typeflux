import AppKit
import SwiftUI

/// Where the developer component gallery can be opened from.
enum ComponentGalleryAccess {
    static let environmentKey = "TYPEFLUX_COMPONENT_GALLERY"
    static let launchArgument = "--component-gallery"

    /// Debug builds always offer the gallery; release builds only when asked for explicitly.
    static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment,
                            arguments: [String] = ProcessInfo.processInfo.arguments,
                            isDebugBuild: Bool = isDebugBuild) -> Bool {
        isDebugBuild || environment[environmentKey] == "1" || arguments.contains(launchArgument)
    }

    /// `--component-gallery` opens the gallery right after launch (used for screenshots).
    static func opensAtLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(launchArgument)
    }

    static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}

/// The appearance the gallery previews, independent of the app setting.
enum ComponentGalleryAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Opens the component gallery, a developer window that shows every shared component.
@MainActor
final class ComponentGalleryWindowController: NSObject, NSWindowDelegate {
    static let shared = ComponentGalleryWindowController()
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.component-gallery")

    private(set) var window: NSWindow?
    private let dock: DockVisibilityController
    private let activate: () -> Void

    init(dock: DockVisibilityController = .shared,
         activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.dock = dock
        self.activate = activate
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.windowIdentifier
        window.title = L("appMenu.componentGallery")
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ComponentGalleryView { [weak window] appearance in
            window?.appearance = appearance.nsAppearance
        })
        window.center()
        self.window = window
        dock.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        activate()
    }

    func windowWillClose(_: Notification) {
        if let window {
            dock.windowDidHide(window)
        }
        window = nil
    }
}
