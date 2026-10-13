import AppKit
import SwiftUI
import Testing
import TypefluxUI

@Suite("TypefluxUI native content menus", .serialized, .exclusiveUIState)
@MainActor
struct TypefluxUIControlsMenuTests {
    // Native menu tracking runs in a dedicated process, like TypefluxPopupMenuTests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_UI_CONTENT_MENUS"] == "1"))
    func `both pop-up styles select and both pull-down styles dispatch`() async throws {
        _ = NSApplication.shared
        var selection = 0
        var selections = 0
        var actions = 0
        let binding = Binding(get: { selection }, set: { selection = $0; selections += 1 })
        let scene = VStack {
            TypefluxPopup("Regular popup", selection: binding) { Text("Automatic").tag(0); Text("Manual").tag(1) }
            TypefluxPopup("Borderless popup", selection: binding, borderless: true) {
                Text("Automatic").tag(0); Text("Manual").tag(1)
            }
            TypefluxMenu { TypefluxButton("Import file") { actions += 1 } } label: { Text("Regular menu") }
            TypefluxMenu(borderless: true) {
                TypefluxButton("Import file") { actions += 1 }
            } label: { Text("Borderless menu") }
        }.padding(24)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: scene)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let controls = descendants(host).compactMap { $0 as? NSPopUpButton }
        #expect(controls.count == 4)
        for control in controls { try chooseNativeItem(using: control) }
        #expect(selection == 1)
        #expect(selections == 2)
        #expect(actions == 2)
    }

    private func chooseNativeItem(using button: NSPopUpButton) throws {
        var selected = false
        var titles: [String] = []
        // SwiftUI populates NSMenu only inside the native tracking loop.
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = button.menu else { return }
                titles = menu.items.map(\.title)
                let index = menu.items.firstIndex { $0.title == "Manual" || $0.title == "Import file" }
                menu.cancelTrackingWithoutAnimation()
                if let index { menu.performActionForItem(at: index); selected = true }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        button.performClick(nil)
        try #require(selected, "Missing item in native menu: \(titles)")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
