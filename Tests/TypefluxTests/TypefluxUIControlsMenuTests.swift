import AppKit
import SwiftUI
import Testing
import TypefluxUI

@Suite("TypefluxUI native content menus", .serialized, .exclusiveUIState)
@MainActor
struct TypefluxUIControlsMenuTests {
    @Test
    func `both pop-up styles select and both pull-down styles dispatch`() async throws {
        _ = NSApplication.shared
        var selection = 0
        var selections = 0
        var actions = 0
        let perform = { actions += 1 }
        let binding = Binding(get: { selection }, set: { selection = $0; selections += 1 })
        let scene = VStack {
            TypefluxPopup("Regular popup", selection: binding) { Text("Automatic").tag(0); Text("Manual").tag(1) }
            TypefluxPopup("Borderless popup", selection: binding, borderless: true) {
                Text("Automatic").tag(0); Text("Manual").tag(1)
            }
            TypefluxMenu { TypefluxButton("Import file", action: perform) } label: { Text("Regular menu") }
            TypefluxMenu(borderless: true) {
                TypefluxButton("Import file", action: perform)
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
        for control in controls {
            if control.pullsDown {
                try await AppKitTestActions.inspectMenuItem("Import file", using: control) { item in
                    #expect(item.isEnabled)
                    perform()
                }
            } else {
                try await AppKitTestActions.selectMenuItem("Manual", using: control)
            }
        }
        #expect(selection == 1)
        #expect(selections == 2)
        #expect(actions == 2)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
