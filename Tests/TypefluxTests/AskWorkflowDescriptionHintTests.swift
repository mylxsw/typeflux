import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskWorkflowDescriptionHintTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `descriptions do not add lines to sections or choices`() {
        let detail = String(repeating: "A long explanation that belongs in a popover. ", count: 12)
        func height(_ view: some View) -> CGFloat {
            NSHostingView(rootView: view.frame(width: 340)).fittingSize.height
        }
        let plain = height(AskWorkflowFormSection(title: "Input", hint: nil) {
            Color.clear.frame(height: 40)
        })
        let described = height(AskWorkflowFormSection(title: "Input", hint: detail) {
            Color.clear.frame(height: 40)
        })
        #expect(abs(plain - described) < 0.5)
        for description in [nil, "", detail] as [String?] {
            let radio = AskWorkflowRadioList(choices: [
                AskWorkflowChoice(value: 0, title: "Text card", detail: description),
                AskWorkflowChoice(value: 1, title: "Items", detail: description)
            ], selection: 0) { _ in }
            #expect(abs(height(radio) - 81) < 0.5)
        }
    }

    @Test func `hovering the label reveals help and hovering help shows the description`() async throws {
        let detail = "A complete description with {output} and multiple lines.\nThe second line stays available."
        try await UI.withFixture { _ in
            try await UI.withWindow(
                AskWorkflowFormSection(title: "Workflow input", hint: detail) {
                    Color.clear.frame(height: 40)
                }.padding(20), width: 420, height: 220
            ) { window, host in
                window.setFrameOrigin(NSPoint(x: 100, y: 100))
                let label = try #require(UI.elements(in: host).first { $0.text == "Workflow input" })
                #expect(!hasPopover(detail, parent: window))
                try hover(label, in: window, inside: true)
                try await UI
                    .wait {
                        UI.elements(in: host)
                            .contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == detail }
                    }
                let help = try UI.button(detail, in: host)
                #expect(help.frame.midX > label.frame.midX)
                #expect(abs(help.frame.midY - label.frame.midY) < 5)
                try hover(help, in: window, inside: true)
                try await UI.wait { hasPopover(detail, parent: window) }
                try hover(help, in: window, inside: false)
                try hover(label, in: window, inside: false)
                try await UI.wait { !hasPopover(detail, parent: window) }
            }
        }
    }

    @Test func `clicking radio help does not select the choice`() async throws {
        var selections: [Int] = []
        let detail = "Use a list when the script prints JSON items."
        try await UI.withFixture { _ in
            let radio = AskWorkflowRadioList(choices: [
                AskWorkflowChoice(value: 0, title: "Text card", detail: nil),
                AskWorkflowChoice(value: 1, title: "Items", detail: detail)
            ], selection: 0) { selections.append($0) }
            try await UI.withWindow(radio.padding(20), width: 420, height: 220) { window, host in
                window.setFrameOrigin(NSPoint(x: 100, y: 100))
                let choice = try UI.button("Items", in: host)
                try hover(choice, in: window, inside: true)
                try await wait("The row reveals its help button") { UI.elements(in: host).contains { $0.label == detail } }
                let help = try UI.button(detail, in: host)
                try click(help.frame, in: window)
                try await wait("Clicking help opens its popover") { hasPopover(detail, parent: window) }
                #expect(selections.isEmpty)
                try help.press()
                try await wait("Clicking pinned help closes its popover") { !hasPopover(detail, parent: window) }
                try choice.press()
                #expect(selections == [1])
                // The blank space after the title remains part of the selectable row.
                let blank = NSRect(x: window.frame.maxX - 40, y: choice.frame.midY - 2, width: 4, height: 4)
                try click(blank, in: window)
                try await wait("Clicking blank row space selects the choice; received \(selections)") { selections.count == 2 }
                #expect(selections == [1, 1])
            }
        }
    }

    @Test func `file examples and action placeholders survive in every language`() {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese, .japanese, .korean] {
            AppLocalization.shared.setLanguage(language)
            let hint = AskWorkflowFilesCard.hint
            for snippet in ["import helper", "require('./helper')", "source ./lib.sh",
                            L("ask.workflow.editor.files.entry"), L("ask.workflow.editor.files.hintDirectory")] {
                #expect(hint.contains(snippet))
            }
            #expect(AskWorkflowOutputForm.actionHint(.onSuccess).hasSuffix("{output}"))
            #expect(AskWorkflowOutputForm.actionHint(.onFailure).hasSuffix("{error}"))
        }
    }

    private func wait(_ reason: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw InteractionTimeout(reason: reason) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct InteractionTimeout: Error {
        var reason: String
    }

    private func hasPopover(_ detail: String, parent: NSWindow) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.parent === parent && UI.contains(detail, in: $0) }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func hover(_ element: UI.Element, in window: NSWindow, inside: Bool) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        var delivered = false
        for view in try descendants(#require(window.contentView)) {
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(view.convert(point, from: nil)),
                      let owner = area.owner as? NSResponder else { continue }
                let event = WorkflowDescriptionHoverEvent(area: area, point: point, window: window, inside: inside)
                if inside { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
                delivered = true
            }
        }
        #expect(delivered)
    }

    private func click(_ frame: NSRect, in window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            try NSApp.sendEvent(#require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil,
                                                            eventNumber: 0, clickCount: 1,
                                                            pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }
}

private final class WorkflowDescriptionHoverEvent: NSEvent {
    private let area: NSTrackingArea
    private let point: NSPoint
    private let targetWindowNumber: Int
    private let eventType: NSEvent.EventType

    init(area: NSTrackingArea, point: NSPoint, window: NSWindow, inside: Bool) {
        self.area = area
        self.point = point
        targetWindowNumber = window.windowNumber
        eventType = inside ? .mouseEntered : .mouseExited
        super.init()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var trackingArea: NSTrackingArea? {
        area
    }

    override var locationInWindow: NSPoint {
        point
    }

    override var windowNumber: Int {
        targetWindowNumber
    }

    override var type: NSEvent.EventType {
        eventType
    }

    override var timestamp: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
