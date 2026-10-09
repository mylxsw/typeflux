import AppKit
import SwiftUI
import Testing
import Vision
@testable import Typeflux

/// Native event tests share the composer's serialized suite with voice input.
extension AskComposerInteractionTests {
    /// The workspace composer lists the source as text; the launcher keeps it out of its footer
    /// (see `narrowLauncherKeepsContentInIconChipsAndMemoryInTheFooter`).
    @Test func sourceChipPreviewsMetadataAndRemovalCanBeUndoneWithoutAScreenshot() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        fixture.model.newConversation()
        fixture.model.draft = AskDraft(text: "Explain this", includeScreenshot: false,
                                       selection: "Selected words", source: "Safari — Example",
                                       sourceBundleID: "com.apple.Safari")
        let window = try await hostSourceContext(AskConversationView(model: fixture.model),
                                                size: NSSize(width: 1100, height: 760))
        defer { window.close(); fixture.model.resetSession() }
        let host = try #require(window.contentView)
        #expect(!(try sourceContainsLabel(in: host, label: L("ask.context.details"))))
        let appLabel = try #require(try sourceText(in: host, matching: "Safari").first)
        let windowLabel = try #require(try sourceText(in: host, matching: "Example").first)
        #expect(windowLabel.frame.minX - appLabel.frame.maxX < 24,
                "A short app name must not reserve the maximum width before the window title")
        try clickSourceText("Safari", in: window)
        let popover = try await waitForSourceControl("ask.context.source.remove")
        defer { if popover !== window { popover.orderOut(nil) } }
        let details = try #require(popover.contentView)
        #expect(try sourceContainsLabel(in: details, label: "Example"))
        #expect(!(try sourceContainsLabel(in: details, label: "Selected words")))
        try clickSourceControl("ask.context.source.remove", in: popover)
        try await fixture.wait { fixture.model.draft.sourceOff == true }
        #expect(fixture.model.draft.source == "Safari — Example")
        #expect(fixture.model.draft.sourceBundleID == "com.apple.Safari")
        #expect(fixture.model.draft.request(deviceId: "device", tools: []).source == nil)
        #expect(fixture.model.draft.request(deviceId: "device", tools: []).selection == "Selected words")
        try await Task.sleep(for: .milliseconds(150))
        try clickSourceControl("ask.context.undo", in: window)
        try await fixture.wait { fixture.model.draft.sourceOff != true }
        #expect(fixture.model.draft.request(deviceId: "device", tools: []).source == "Safari — Example")
    }

    @Test func plusMenuRestoresSourceAndSelectionIndependently() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft = AskDraft(text: "Explain this", includeScreenshot: false,
                                               selection: "First line\nSecond line", source: "Safari — Example",
                                               sourceOff: true, selectionOff: true)
        let window = try await hostSourceContext(AskLauncherView(model: fixture.model, onDismiss: {}),
                                                size: NSSize(width: AskMetrics.launcherWidth, height: 260))
        defer { window.close(); fixture.model.resetSession() }
        let host = try #require(window.contentView)
        try clickSourceChip(try #require(sourceChipAnchors(host).first), in: window)
        let sourceMenu = try await waitForSourceControl("ask.attach.title")
        try clickSourceText(L("ask.context.restore.source", "Safari"), in: sourceMenu)
        try await fixture.wait { fixture.model.launcherDraft.sourceOff != true }
        #expect(fixture.model.launcherDraft.selectionOff == true)
        try await Task.sleep(for: .milliseconds(150))
        try clickSourceChip(try #require(sourceChipAnchors(host).first), in: window)
        let selectionMenu = try await waitForSourceControl("ask.attach.title")
        try clickSourceText(L("ask.context.restore.selection", 2), in: selectionMenu)
        try await fixture.wait { fixture.model.launcherDraft.selectionOff != true }
        #expect(fixture.model.launcherDraft.sentSource == "Safari — Example")
        #expect(fixture.model.launcherDraft.sentSelection == "First line\nSecond line")
    }

    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func narrowLauncherKeepsContentInIconChipsAndMemoryInTheFooter(_ language: AppLanguage) async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(language)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let suite = "ask-source-narrow-local-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let width: CGFloat = language == .simplifiedChinese ? 430 : 480
        let profile = AskModelProfile(name: "Local reasoning assistant with a long profile name",
                                      baseURL: "http://127.0.0.1:11434/v1", model: "typeflux/assistant-dev")
        try defaults.set(JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        library.defaultReference = profile.reference
        let fixture = try AskTestFixture(localOnly: true, modelLibrary: library)
        fixture.model.launcherDraft = AskDraft(text: "Explain this", includeScreenshot: false,
                                               selection: "Selected words that need a separate row",
                                               source: "Safari — A long page title that must fit in this window",
                                               sourceBundleID: "com.apple.Safari")
        let memory = AskMemory(global: "Saved preferences")
        fixture.model.launcherDraft.memory = memory
        let window = try await hostSourceContext(AskLauncherView(model: fixture.model, onDismiss: {}),
                                                size: NSSize(width: width, height: 280))
        defer { window.close(); fixture.model.resetSession() }
        window.setContentSize(NSSize(width: width, height: window.contentView?.bounds.height ?? 280))
        try await Task.sleep(for: .milliseconds(100))
        let host = try #require(window.contentView)
        let anchors = sourceChipAnchors(host)
        #expect(anchors.count >= 3, "The attachment menu, screenshot, and memory remain in the footer")
        for anchor in anchors {
            #expect(host.bounds.contains(anchor.convert(anchor.bounds, to: host)))
        }
        let voice = try #require(sourceVoiceButton(in: host))
        let voiceFrame = voice.convert(voice.bounds, to: host)
        let sendFrame = CGRect(x: voiceFrame.maxX + 4, y: voiceFrame.midY - AskSendButton.size / 2,
                               width: AskSendButton.size, height: AskSendButton.size)
        #expect(host.bounds.contains(sendFrame))
        #expect(abs(host.bounds.width - width) < 0.5)
        #expect(!(try sourceContainsLabel(in: host, label: L("ask.context.details"))))
        // The launcher footer draws content as icon chips; source and selection words live in
        // hover cards, so a long window title cannot crowd the footer at any width.
        #expect(try sourceText(in: host, matching: "Safari").isEmpty)
        #expect(try sourceText(in: host, matching: "Selected").isEmpty)
        #expect(fixture.model.launcherDraft.sentSource == "Safari — A long page title that must fit in this window")
        #expect(fixture.model.launcherDraft.sentSelection == "Selected words that need a separate row")
        try clickSourceChip(try #require(anchors.last), in: window)
        try await fixture.wait { fixture.model.launcherDraft.memoryOff == true }
        #expect(fixture.model.launcherDraft.memory == memory)
        try clickSourceChip(try #require(sourceChipAnchors(host).last), in: window)
        try await fixture.wait { fixture.model.launcherDraft.memoryOff != true }
    }

    @Test func selectedTextPreviewCanRemoveOnlyTheSelection() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        fixture.model.newConversation()
        fixture.model.draft = AskDraft(text: "Explain this", includeScreenshot: false,
                                       selection: "Selected words", source: "Safari — Example")
        let window = try await hostSourceContext(AskConversationView(model: fixture.model),
                                                size: NSSize(width: 1100, height: 760))
        defer { window.close(); fixture.model.resetSession() }
        try clickSourceText("Selected words", in: window)
        let popover = try await waitForSourceControl("ask.selection.remove")
        defer { if popover !== window { popover.orderOut(nil) } }
        try clickSourceControl("ask.selection.remove", in: popover)
        try await fixture.wait { fixture.model.draft.selectionOff == true }
        #expect(fixture.model.draft.sentSource == "Safari — Example")
        #expect(fixture.model.draft.selection == "Selected words")
        #expect(fixture.model.draft.sentSelection == nil)
    }

    @Test func refreshIconIsAnExplicitActionAndDisabledWhileCapturing() async throws {
        var refreshes = 0
        for disabled in [false, true] {
            let window = try await hostSourceContext(
                AskSourceRefreshButton(help: "Use current app and clear old selection", disabled: disabled) { refreshes += 1 },
                size: NSSize(width: 24, height: 24))
            defer { window.close() }
            #expect(refreshes == (disabled ? 1 : 0), "Rendering must not replace captured content")
            try sendSourceClick(at: NSPoint(x: 12, y: 12), in: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(refreshes == 1)
        }
    }

    @Test func screenshotInventoryOffersRecoveryAndPreviewAsSeparateActions() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        var previews = 0
        var retries = 0
        var removed: [AskContextItem.Kind] = []
        var draft = AskDraft(includeScreenshot: true)
        let failed = AskAttachmentStrip.contentItems(draft: draft,
                                                     screenshotState: .failed(permission: false, message: "Capture failed"))
        let retryWindow = try await hostSourceContext(
            AskAttachmentStripView(items: failed, onPreview: { previews += 1 }, onRemove: { removed.append($0) },
                                   onScreenshotAction: { retries += 1 }),
            size: NSSize(width: 430, height: 60))
        defer { retryWindow.close() }
        try clickSourceText(L("ask.context.screen.retry"), in: retryWindow)
        #expect(retries == 1)
        #expect(previews == 0)
        #expect(removed.isEmpty)
        draft.screenshot = "data:image/png;base64,screen"
        let ready = AskAttachmentStrip.contentItems(draft: draft, screenshotState: .attached)
        let previewWindow = try await hostSourceContext(
            AskAttachmentStripView(items: ready, screenshot: NSImage(size: NSSize(width: 32, height: 22)),
                                   onPreview: { previews += 1 }, onRemove: { removed.append($0) }),
            size: NSSize(width: 430, height: 60))
        defer { previewWindow.close() }
        try clickSourceText(L("ask.context.screen.full"), in: previewWindow)
        #expect(previews == 1)
        #expect(retries == 1)
        #expect(removed.isEmpty)
    }

    @Test func workspaceSourceRemovalPreservesSelectedText() async throws {
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
        try clickSourceText("Finder", in: window)
        let popover = try await waitForSourceControl("ask.context.source.remove")
        defer { if popover !== window { popover.orderOut(nil) } }
        try clickSourceControl("ask.context.source.remove", in: popover)
        try await fixture.wait { fixture.model.draft.sourceOff == true }
        #expect(fixture.model.draft.sentSource == nil)
        #expect(fixture.model.draft.sentSelection == "Saved words")
    }

    private func clickSourceText(_ label: String, in window: NSWindow) throws {
        let root = try #require(window.contentView)
        let labels = try sourceText(in: root).map(\.text)
        let frame = try #require(try sourceText(in: root, matching: label).first?.frame,
                                 "Missing label: \(label); found \(labels)")
        try sendSourceClick(at: root.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil), in: window)
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
        if identifier == "ask.context.source.remove" || identifier == "ask.context.source.restore"
            || identifier == "ask.selection.remove" {
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

@MainActor
private final class SourceContextTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
