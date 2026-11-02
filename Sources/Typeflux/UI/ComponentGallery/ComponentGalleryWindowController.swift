import AppKit
import SwiftUI

/// Where the developer component gallery can be opened from.
enum ComponentGalleryAccess {
    static let launchArgument = "--component-gallery"

    /// The gallery is a development tool and is never available in production builds.
    static func isAvailable(isDebugBuild: Bool = isDebugBuild) -> Bool {
        isDebugBuild
    }

    /// `--component-gallery` opens the gallery for development screenshots only.
    static func opensAtLaunch(arguments: [String] = ProcessInfo.processInfo.arguments,
                              isDebugBuild: Bool = isDebugBuild) -> Bool {
        isAvailable(isDebugBuild: isDebugBuild) && arguments.contains(launchArgument)
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
         activate: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.dock = dock
        self.activate = activate
        super.init()
    }

    func show() {
        guard ComponentGalleryAccess.isAvailable() else { return }
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
