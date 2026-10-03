import AppKit
import SwiftUI
import Testing
import Vision
@testable import Typeflux

/// Keep native mouse delivery in the composer's serialized suite: voice-input
/// tests install application-wide event monitors while they run.
extension AskComposerInteractionTests {
    @Test func sourceDetailsRemainReachableWithoutAScreenshotAndRestoreMetadata() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft = AskDraft(text: "Explain this", includeScreenshot: false,
                                               selection: "Selected words", source: "Safari — Example",
                                               sourceBundleID: "com.apple.Safari")
        let window = try await hostSourceContext(AskLauncherView(model: fixture.model, onDismiss: {}),
                                                size: NSSize(width: AskMetrics.launcherWidth, height: 150))
        defer { window.close(); fixture.model.resetSession() }
        try clickSourceControl("ask.context.details", in: window)
        let popover = try await waitForSourceControl("ask.context.source.remove")
        defer { if popover !== window { popover.orderOut(nil) } }
        try clickSourceControl("ask.context.source.remove", in: popover)
        try await fixture.wait { fixture.model.launcherDraft.sourceOff == true }
        #expect(fixture.model.launcherDraft.source == "Safari — Example")
        #expect(fixture.model.launcherDraft.sourceBundleID == "com.apple.Safari")
        #expect(fixture.model.launcherDraft.selection == "Selected words")
        #expect(fixture.model.launcherDraft.request(deviceId: "device", tools: []).source == nil)
        #expect(fixture.model.launcherDraft.request(deviceId: "device", tools: []).selection == "Selected words")
        let restoredPopover = try await waitForSourceControl("ask.context.source.restore")
        try clickSourceControl("ask.context.source.restore", in: restoredPopover)
        try await fixture.wait { fixture.model.launcherDraft.sourceOff != true }
        #expect(fixture.model.launcherDraft.request(deviceId: "device", tools: []).source == "Safari — Example")
    }

    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func narrowLocalLauncherKeepsContextAndFoldedMemoryUsable(_ language: AppLanguage) async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(language)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let suite = "ask-source-narrow-local-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let width: CGFloat = language == .simplifiedChinese ? 430 : 480
        let name = language == .simplifiedChinese ? "Local model" : "Local reasoning assistant with a long profile name"
        let profile = AskModelProfile(name: name,
                                      baseURL: "http://127.0.0.1:11434/v1", model: "typeflux/assistant-dev")
        try defaults.set(JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        library.defaultReference = profile.reference
        let fixture = try AskTestFixture(localOnly: true, modelLibrary: library)
        if language == .english { fixture.model.reasoningEffort = .high }
        fixture.model.launcherDraft = AskDraft(text: "Explain this", includeScreenshot: false,
                                               source: "Safari", sourceBundleID: "com.apple.Safari")
        let memory = AskMemory(global: "Saved preferences")
        fixture.model.launcherDraft.memory = memory
        let window = try await hostSourceContext(AskLauncherView(model: fixture.model, onDismiss: {}),
                                                size: NSSize(width: width, height: 150))
        defer { window.close(); fixture.model.resetSession() }
        // The real launcher constrains its frame after creating its hosting view.
        window.setContentSize(NSSize(width: width, height: window.contentView?.bounds.height ?? 150))
        try await Task.sleep(for: .milliseconds(100))
        let host = try #require(window.contentView)
        let attach = try #require(sourceChipAnchors(host).first)
        let attachFrame = attach.convert(attach.bounds, to: host)
        #expect(attachFrame.width == AskMetrics.composerControlHeight)
        #expect(host.bounds.contains(attachFrame), "Attach must fit: \(attachFrame), host \(host.bounds)")
        let voice = try #require(sourceVoiceButton(in: host))
        let voiceFrame = voice.convert(voice.bounds, to: host)
        // Send immediately follows this native control in the production HStack.
        let sendFrame = CGRect(x: voiceFrame.maxX + 4, y: voiceFrame.midY - AskSendButton.size / 2,
                               width: AskSendButton.size, height: AskSendButton.size)
        #expect(host.bounds.contains(sendFrame), "Send must fit: \(sendFrame), host \(host.bounds)")
        #expect(abs(window.frame.width - width) < 0.5)
        #expect(abs(host.bounds.width - width) < 0.5, "The fallback must not widen the hosting view")
        let entry = try #require(try sourceControl(in: host, identifier: "ask.context.details"))
        #expect(host.bounds.contains(entry), "The context entry must stay inside the narrow composer")
        try clickSourceControl("ask.context.details", in: window)
        let popover = try await waitForSourceControl("ask.context.source.remove")
        defer { if popover !== window { popover.orderOut(nil) } }
        let details = try #require(popover.contentView)
        // These are the production hover anchors for the screenshot and memory
        // chips moved into the popover, not a second set of test-only controls.
        #expect(sourceChipAnchors(details).count == 2)
        try clickSourceChip(try #require(sourceChipAnchors(details).last), in: popover)
        try await fixture.wait { fixture.model.launcherDraft.memoryOff == true }
        #expect(fixture.model.memorySwitchedOff(launcher: true))
        #expect(fixture.model.launcherDraft.memory == memory)
        try clickSourceChip(try #require(sourceChipAnchors(details).last), in: popover)
        try await fixture.wait { fixture.model.launcherDraft.memoryOff != true }
        #expect(!fixture.model.memorySwitchedOff(launcher: true))
        try clickSourceControl("ask.context.source.remove", in: popover)
        try await fixture.wait { fixture.model.launcherDraft.sourceOff == true }
        #expect(fixture.model.launcherDraft.source == "Safari")
        #expect(fixture.model.launcherDraft.request(deviceId: "device", tools: []).source == nil)
    }

    @Test func workspaceDraftSourceCanBeRemovedWithoutACaptureAction() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        fixture.model.newConversation()
        fixture.model.draft = AskDraft(text: "Continue this question", includeScreenshot: false,
                                       selection: "Saved words", source: "Finder — Saved document")
        let window = try await hostSourceContext(AskConversationView(model: fixture.model),
                                                size: NSSize(width: 1100, height: 760))
        defer { window.close(); fixture.model.resetSession() }
        try clickSourceControl("ask.context.details", in: window)
        let popover = try await waitForSourceControl("ask.context.source.remove")
        defer { if popover !== window { popover.orderOut(nil) } }
        let root = try #require(popover.contentView)
        #expect(try sourceControl(in: root, identifier: "ask.context.refresh") == nil)
        try clickSourceControl("ask.context.source.remove", in: popover)
        try await fixture.wait { fixture.model.draft.sourceOff == true }
        #expect(fixture.model.draft.source == "Finder — Saved document")
        #expect(fixture.model.draft.request(deviceId: "device", tools: []).source == nil)
        #expect(fixture.model.draft.request(deviceId: "device", tools: []).selection == "Saved words")
    }

    @Test func contextRefreshIsExplicitAndDisabledWhileCapturing() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft = AskDraft(text: "Question", includeScreenshot: false,
                                               selection: "Old selection", source: "Finder — Saved draft")
        fixture.model.launcherDraft.sourceOff = true
        var refreshes = 0
        for capturing in [false, true] {
            let window = try await hostSourceContext(
                SourceDetailsTestHost(model: fixture.model, restored: true, capturing: capturing) { refreshes += 1 },
                size: NSSize(width: 430, height: 440))
            defer { window.close() }
            #expect(refreshes == (capturing ? 1 : 0), "Rendering must not refresh captured context")
            try clickSourceControl("ask.context.refresh", in: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(refreshes == 1)
            #expect(fixture.model.launcherDraft.sourceOff == true)
            #expect(fixture.model.launcherDraft.source == "Finder — Saved draft")
            #expect(fixture.model.launcherDraft.selection == "Old selection")
        }
        fixture.model.resetSession()
    }

    @Test func unknownSourceHasNoMetadataToggleButKeepsRefreshAvailable() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        for selection in [nil, ""] as [String?] {
            fixture.model.launcherDraft = AskDraft(text: "Question", includeScreenshot: false, selection: selection)
            let window = try await hostSourceContext(SourceDetailsTestHost(model: fixture.model) {},
                                                     size: NSSize(width: 430, height: 400))
            defer { window.close() }
            let root = try #require(window.contentView)
            #expect(try sourceControl(in: root, identifier: "ask.context.source.remove") == nil)
            #expect(try sourceControl(in: root, identifier: "ask.context.source.restore") == nil)
            #expect(try sourceControl(in: root, identifier: "ask.context.refresh") != nil)
            #expect(try sourceContainsLabel(in: root, label: L("ask.context.source.none")))
            #expect(try sourceContainsLabel(in: root, label: L("ask.context.selection.excluded")))
        }
    }

    /// SwiftUI does not vend accessibility children in a headless Swift Testing
    /// process. Recognize the fixture window's rendered labels instead, then
    /// send the same native mouse events as the other composer interaction tests.
    /// No screen capture permission or desktop pixels are involved.
    private func sourceText(in root: NSView, matching label: String? = nil) throws -> [(text: String, frame: CGRect)] {
        root.layoutSubtreeIfNeeded()
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = AppLocalization.shared.language == .simplifiedChinese
            ? ["zh-Hans", "en-US"] : ["en-US"]
        request.usesLanguageCorrection = true
        request.customWords = ["ask.context.details", "ask.context.source.remove", "ask.context.source.restore",
                               "ask.context.refresh"].map { L($0) }
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let bounds: CGRect
            if let label {
                // OCR may merge neighboring controls into one line. Click the
                // matched words, not the center of that entire toolbar line.
                guard let range = candidate.string.range(of: label),
                      let match = try? candidate.boundingBox(for: range) else { return nil }
                bounds = match.boundingBox
            } else {
                bounds = observation.boundingBox
            }
            // Vision measures from the bottom left; NSHostingView is flipped.
            let y = root.isFlipped ? 1 - bounds.maxY : bounds.minY
            let frame = CGRect(x: bounds.minX * root.bounds.width, y: y * root.bounds.height,
                               width: bounds.width * root.bounds.width, height: bounds.height * root.bounds.height)
            return (candidate.string, frame)
        }
    }

    private func sourceContainsLabel(in root: NSView, label: String) throws -> Bool {
        try sourceText(in: root).contains { $0.text.contains(label) }
    }

    private func sourceControl(in root: NSView, identifier: String) throws -> CGRect? {
        let label = sourceControlLabel(identifier)
        return try sourceText(in: root, matching: label).first?.frame
    }

    private func sourceControlWindow(_ identifier: String) -> NSWindow? {
        NSApp.windows.first { window in
            guard window.isVisible, let root = window.contentView else { return false }
            return (try? sourceControl(in: root, identifier: identifier)) != nil
        }
    }

    private func waitForSourceControl(_ identifier: String) async throws -> NSWindow {
        for _ in 0..<10 {
            if let window = sourceControlWindow(identifier) { return window }
            try await Task.sleep(for: .milliseconds(100))
        }
        let labels = NSApp.windows.filter(\.isVisible).compactMap { $0.contentView }
            .flatMap { (try? sourceText(in: $0).map(\.text)) ?? [] }
        let missing: NSWindow? = nil
        return try #require(missing, "Missing popover control: \(identifier); rendered labels: \(labels)")
    }

    private func sourceControlLabel(_ identifier: String) -> String {
        let label = L(identifier)
        // The action and its object identify the button. Small popover fonts
        // can make OCR confuse the final letter of "info"; the clicked action
        // is verified against the bound draft and outgoing request below.
        if identifier == "ask.context.source.remove" || identifier == "ask.context.source.restore" {
            return label.split(separator: " ").prefix(2).joined(separator: " ")
        }
        return label
    }

    private func clickSourceControl(_ identifier: String, in window: NSWindow) throws {
        let root = try #require(window.contentView)
        let labels = try sourceText(in: root)
        let frame = try #require(try sourceControl(in: root, identifier: identifier),
                                 "Missing \(identifier); rendered labels: \(labels.map(\.text))")
        let point = root.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        try sendSourceClick(at: point, in: window)
    }

    private func sendSourceClick(at point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
    }

    private func sourceVoiceButton(in root: NSView) -> AskVoiceButton.Control? {
        (root as? AskVoiceButton.Control) ?? root.subviews.lazy.compactMap { sourceVoiceButton(in: $0) }.first
    }

    private func sourceChipAnchors(_ root: NSView) -> [NSView] {
        func walk(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)).contains("Passthrough") ? [view] : []) + view.subviews.flatMap(walk)
        }
        return walk(root).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func clickSourceChip(_ anchor: NSView, in window: NSWindow) throws {
        let frame = anchor.convert(anchor.bounds, to: nil)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        try sendSourceClick(at: point, in: window)
    }

    private func hostSourceContext<V: View>(_ view: V, size: NSSize) async throws -> NSWindow {
        _ = NSApplication.shared
        let window = SourceContextTestWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view.environment(\.askGlassMaterialOverride, .opaque)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        return window
    }
}

private struct SourceDetailsTestHost: View {
    @ObservedObject var model: AskConversationModel
    var restored = false
    var capturing = false
    var refresh: () -> Void

    var body: some View {
        AskSourceContextDetails(draft: $model.launcherDraft, restored: restored, capturing: capturing, refresh: refresh)
    }
}

@MainActor
private final class SourceContextTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
