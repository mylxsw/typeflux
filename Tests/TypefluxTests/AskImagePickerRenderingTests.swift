import AppKit
import SwiftUI
import Testing
@testable import Typeflux

// Share the serialized suite: localization and native window focus are process-wide.
extension AskConversationVisualTests {
    @Test func rendersRecoveryStatesInAnActivePopover() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try await AskImageCapabilityTests().fixture()
        defer { fixture.model.resetSession() }
        let value = AskImageCapabilityTests().conversation()
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        let library = fixture.model.modelLibrary
        // Real model names, synthetic prices; no live catalog or account is accessed.
        let cloud = RegisteredProvider(id: "typefluxCloud", name: "Typeflux Cloud", remote: .typefluxCloud, models: [
            .init(id: "gpt-4.1", name: "GPT-4.1", reference: "cloud:gpt-4.1", vision: true, pricing: .init(multiplier: "1")),
            .init(id: "claude", name: "Claude Sonnet 4", reference: "cloud:claude", vision: true, pricing: .init(multiplier: "2"))
        ])
        let custom = RegisteredProvider(id: "custom", name: "OpenAI", baseURL: "https://example.invalid/v1", models: [
            .init(id: "long", name: "GPT-4.1 — Design review and screenshot analysis workspace", reference: "custom:long", vision: true)
        ])
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let conversation = NSHostingView(rootView: AskConversationView(model: fixture.model))
        parent.contentView = conversation
        parent.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { parent.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            parent.appearance = NSAppearance(named: appearance)
            for scenario in ["normal", "single", "loading", "failure", "partial", "empty", "signed-out", "many", "no-screenshot", "current", "refreshing", "busy"] {
                var registry = library.registry
                switch scenario {
                case "normal": registry.providers = [cloud, custom]
                case "single", "partial", "no-screenshot", "current", "refreshing", "busy": registry.providers = [custom]
                case "many":
                    var many = custom
                    many.models = (0..<15).map { .init(id: "model-\($0)", name: "GPT-4.1 — Workspace \($0)", reference: "custom:\($0)", vision: true) }
                    registry.providers = [many]
                default: registry.providers = []
                }
                try library.commit(registry)
                library.catalogError = ["failure", "partial"].contains(scenario) ? "Internal catalog error" : nil
                var actions: [String] = []
                let view = AskImagePickerContent(library: library, candidate: .constant(scenario == "normal" ? "cloud:gpt-4.1" : "custom:long"),
                    currentReference: scenario == "current" ? "custom:long" : "cloud:text",
                    loggedIn: scenario != "signed-out", loading: ["loading", "refreshing"].contains(scenario),
                    hasSavedScreenshot: scenario != "no-screenshot", busy: scenario == "busy", dismiss: { actions.append("cancel") },
                    refresh: { actions.append("retry") }, configure: { actions.append("settings") },
                    signIn: { actions.append("signIn") }, resume: { actions.append("resume") })
                let controller = NSHostingController(rootView: view)
                let popover = NSPopover()
                popover.contentViewController = controller
                popover.behavior = .transient
                popover.animates = false
                popover.show(relativeTo: NSRect(x: 600, y: 80, width: 10, height: 10), of: conversation, preferredEdge: .maxY)
                defer { popover.close() }
                try await Task.sleep(for: .milliseconds(150))
                controller.view.layoutSubtreeIfNeeded()
                let size = controller.view.fittingSize
                #expect(size.width >= 350 && size.width <= 380)
                #expect(size.height < 580, "The list must scroll without moving footer actions offscreen")
                if scenario == "single" { #expect(size.height > 210 && size.height < 300, "The full two-line model row must fit without a tall blank list") }
                if scenario == "normal" { #expect(size.height > 300, "All three choices and both provider headings must be visible") }
                controller.view.setFrameSize(size)
                popover.contentSize = size
                controller.view.window?.makeKey()
                try await Task.sleep(for: .milliseconds(100))
                let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 4000)
                let theme = appearance == .aqua ? "light" : "dark"
                try png.write(to: root.appendingPathComponent("picker-\(scenario)-\(theme).png"))
                let keyWindow = try #require(controller.view.window)
                let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: keyWindow.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                _ = keyWindow.performKeyEquivalent(with: enter)
                let expected: [String]
                switch scenario {
                case "failure": expected = ["retry"]
                case "empty": expected = ["settings"]
                case "signed-out": expected = ["signIn"]
                case "loading", "many", "busy": expected = []
                default: expected = ["resume"]
                }
                #expect(actions == expected, "Return must invoke only the relevant enabled action: \(scenario)")
                actions.removeAll()
                let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: keyWindow.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                _ = keyWindow.performKeyEquivalent(with: escape)
                #expect(actions == ["cancel"], "Escape must leave recovery without submitting")
                popover.close()
            }
        }
        // Exercise the production wrapper as well as its presentation: switching conversations
        // must dismiss a picker tied to the old run without submitting a retry.
        fixture.model.selectModel("custom:long", launcher: false)
        let target = try #require(fixture.model.imageRecoveryTarget)
        var dismissed = false
        let wrapper = NSHostingController(rootView: AskImageRecoveryPicker(model: fixture.model, target: target) {
            dismissed = true
        })
        let popover = NSPopover()
        popover.contentViewController = wrapper
        popover.animates = false
        popover.show(relativeTo: NSRect(x: 600, y: 80, width: 10, height: 10), of: conversation, preferredEdge: .maxY)
        defer { popover.close() }
        try await Task.sleep(for: .milliseconds(150))
        let other = AskImageCapabilityTests().conversation("other")
        await fixture.api.seed(other)
        await fixture.model.select(other.id)
        try await fixture.wait { dismissed }
        #expect(await fixture.api.retryModels.isEmpty)
        #expect(fixture.model.selected?.messages == other.messages)
    }
}
