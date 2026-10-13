import AppKit
import Testing

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskWorkspaceAccessibilityTests {
    @Test func identifiersCanBelongToAContainerOrItsButton() throws {
        TypefluxTestApplicationEnvironment.prepare()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: .zero)
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier("fixture.container")
        let button = NSButton(title: "Child", target: nil, action: nil)
        button.setAccessibilityLabel("Child")
        container.addSubview(button)
        container.setAccessibilityChildren([button])
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        try AskWorkspaceTestAccessibility.assertButton("fixture.container", label: "Child", in: window)
        button.setAccessibilityIdentifier("fixture.button")
        try AskWorkspaceTestAccessibility.assertButton("fixture.button", label: "Child", in: window)
    }
}
