import AppKit
import SwiftUI

@MainActor
final class TypefluxGalleryWindowController: NSObject {
    static let shared = TypefluxGalleryWindowController()
    private let state = TypefluxGalleryState()
    var style: InterfaceStyle {
        get { state.style }
        set { state.style = newValue }
    }

    var appearance: ColorScheme {
        get { state.appearance }
        set {
            state.appearance = newValue
            window?.appearance = NSAppearance(named: newValue == .dark ? .darkAqua : .aqua)
        }
    }

    private(set) var window: NSWindow?
    private let activateApplication: @MainActor () -> Void

    init(activateApplication: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.activateApplication = activateApplication
        super.init()
    }

    static var labels: TypefluxGalleryLabels {
        TypefluxGalleryLabels(style: "Style", classic: "Classic", liquidGlass: "Liquid Glass",
                              appearance: "Appearance", light: "Light", dark: "Dark",
                              colors: "Semantic colors", typography: "Text styles", metrics: "Metrics (pt)",
                              sampleText: "Typeflux")
    }

    @objc func showGallery() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "TypefluxUI Component Gallery"
            window.identifier = NSUserInterfaceItemIdentifier("typeflux.component-gallery")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 500)
            // The controller owns the window; closures must not keep the controller alive.
            window.contentView = NSHostingView(rootView: TypefluxGalleryRoot(state: state) { [weak self] appearance in
                self?.window?.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            })
            window.center()
            self.window = window
        }
        window?.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        window?.makeKeyAndOrderFront(nil)
        activateApplication()
    }
}
