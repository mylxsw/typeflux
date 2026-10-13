import AppKit
import SwiftUI
import Testing
import Vision
@testable import Typeflux

/// Verify context rendering and accessibility, then drive captured-content model actions without UI tracking.
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
        try AskWorkspaceTestAccessibility.assertButton("ask.content.source.preview", label: "Safari", in: window)
        let popover = try await sourceDetails(for: fixture.model)
        defer { popover.close() }
        let details = try #require(popover.contentView)
        #expect(try sourceContainsLabel(in: details, label: "Example"))
        #expect(!(try sourceContainsLabel(in: details, label: "Selected words")))
        try AskWorkspaceTestAccessibility.assertButton("ask.context.source.remove",
                                                      label: L("ask.context.source.remove"), in: popover)
        fixture.model.removeCapturedContent(.source, launcher: false)
        try await fixture.wait { fixture.model.draft.sourceOff == true }
        #expect(fixture.model.draft.source == "Safari — Example")
        #expect(fixture.model.draft.sourceBundleID == "com.apple.Safari")
        #expect(fixture.model.draft.request(deviceId: "device", tools: []).source == nil)
        #expect(fixture.model.draft.request(deviceId: "device", tools: []).selection == "Selected words")
        try await Task.sleep(for: .milliseconds(150))
        _ = try #require(AskWorkspaceTestAccessibility.elements(in: window).first { $0.label == L("ask.context.undo") })
        fixture.model.undoCapturedContent(launcher: false)
        try await fixture.wait { fixture.model.draft.sourceOff != true }
        #expect(fixture.model.draft.request(deviceId: "device", tools: []).source == "Safari — Example")
    }

    @Test func capturedContentRestoresSourceAndSelectionIndependently() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        fixture.model.launcherDraft = AskDraft(text: "Please use the attached context", includeScreenshot: false,
                                               selection: "First line\nSecond line", source: "Safari — Example",
                                               sourceOff: true, selectionOff: true)
        let window = try await hostSourceContext(AskLauncherView(model: fixture.model, onDismiss: {}),
                                                size: NSSize(width: AskMetrics.launcherWidth, height: 260))
        defer { window.close(); fixture.model.resetSession() }
        _ = try AskWorkspaceTestAccessibility.center(identifier: "ask.composer.attach", in: window)
        fixture.model.restoreCapturedContent(.source, launcher: true)
        #expect(fixture.model.launcherDraft.selectionOff == true)
        fixture.model.restoreCapturedContent(.selection, launcher: true)
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
        fixture.model.toggleMemory(launcher: true)
        try await fixture.wait { fixture.model.launcherDraft.memoryOff == true }
        #expect(fixture.model.launcherDraft.memory == memory)
        fixture.model.toggleMemory(launcher: true)
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
        _ = try AskWorkspaceTestAccessibility.center(identifier: "ask.content.selection.preview", in: window)
        let popover = try await hostSourceContext(AskSelectedTextDetails(
            text: "Selected words", source: "Safari", onRemove: {
                fixture.model.removeCapturedContent(.selection, launcher: false)
            }), size: NSSize(width: 360, height: 360))
        defer { popover.close() }
        #expect(try sourceContainsLabel(in: #require(popover.contentView), label: "Selected words"))
        try AskWorkspaceTestAccessibility.assertButton("ask.selection.remove",
                                                      label: L("ask.selection.remove"), in: popover)
        fixture.model.removeCapturedContent(.selection, launcher: false)
        try await fixture.wait { fixture.model.draft.selectionOff == true }
        #expect(fixture.model.draft.sentSource == "Safari — Example")
        #expect(fixture.model.draft.selection == "Selected words")
        #expect(fixture.model.draft.sentSelection == nil)
    }

    @Test func refreshIconIsAnExplicitActionAndDisabledWhileCapturing() async throws {
        var refreshes = 0
        let refresh = { refreshes += 1 }
        for disabled in [false, true] {
            let window = try await hostSourceContext(
                AskSourceRefreshButton(help: "Use current app and clear old selection",
                                       disabled: disabled, action: refresh),
                size: NSSize(width: 24, height: 24))
            defer { window.close() }
            #expect(refreshes == (disabled ? 1 : 0), "Rendering must not replace captured content")
            let button = try #require(AskWorkspaceTestAccessibility.elements(in: window).first {
                $0.value("accessibilityIdentifier") as? String == "ask.context.refresh"
            })
            #expect(button.value("isAccessibilityEnabled") as? Bool == !disabled)
            if !disabled { refresh() }
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
        let preview = { previews += 1 }
        let retry = { retries += 1 }
        var removed: [AskContextItem.Kind] = []
        var draft = AskDraft(includeScreenshot: true)
        let failed = AskAttachmentStrip.contentItems(draft: draft,
                                                     screenshotState: .failed(permission: false, message: "Capture failed"))
        let retryWindow = try await hostSourceContext(
            AskAttachmentStripView(items: failed, onPreview: preview, onRemove: { removed.append($0) },
                                   onScreenshotAction: retry),
            size: NSSize(width: 430, height: 60))
        defer { retryWindow.close() }
        _ = try AskWorkspaceTestAccessibility.center(identifier: "ask.content.screenshot.action", in: retryWindow)
        retry()
        #expect(retries == 1)
        #expect(previews == 0)
        #expect(removed.isEmpty)
        draft.screenshot = "data:image/png;base64,screen"
        let ready = AskAttachmentStrip.contentItems(draft: draft, screenshotState: .attached)
        let previewWindow = try await hostSourceContext(
            AskAttachmentStripView(items: ready, screenshot: NSImage(size: NSSize(width: 32, height: 22)),
                                   onPreview: preview, onRemove: { removed.append($0) }),
            size: NSSize(width: 430, height: 60))
        defer { previewWindow.close() }
        _ = try AskWorkspaceTestAccessibility.center(identifier: "ask.content.screenshot.preview", in: previewWindow)
        preview()
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
        try AskWorkspaceTestAccessibility.assertButton("ask.content.source.preview", label: "Finder", in: window)
        let popover = try await sourceDetails(for: fixture.model)
        defer { popover.close() }
        try AskWorkspaceTestAccessibility.assertButton("ask.context.source.remove",
                                                      label: L("ask.context.source.remove"), in: popover)
        fixture.model.removeCapturedContent(.source, launcher: false)
        try await fixture.wait { fixture.model.draft.sourceOff == true }
        #expect(fixture.model.draft.sentSource == nil)
        #expect(fixture.model.draft.sentSelection == "Saved words")
    }

    private func sourceDetails(for model: AskConversationModel) async throws -> NSWindow {
        try await hostSourceContext(AskSourceContextDetails(
            draft: Binding(get: { model.draft }, set: { model.draft = $0 }),
            onRemove: { model.removeCapturedContent(.source, launcher: false) }),
            size: NSSize(width: 340, height: 300))
    }

    /// Recognize only this fixture's rendered content, without desktop capture or event simulation.
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
                // Vision can lowercase a button label. Match whole words so
                // "Attach" cannot select a preview containing "attached".
                let escaped = NSRegularExpression.escapedPattern(for: label)
                let pattern = "(?<!\\w)\(escaped)(?!\\w)"
                guard let range = candidate.string.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
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

    private func sourceVoiceButton(in root: NSView) -> AskVoiceButton.Control? {
        (root as? AskVoiceButton.Control) ?? root.subviews.lazy.compactMap { sourceVoiceButton(in: $0) }.first
    }

    private func sourceChipAnchors(_ root: NSView) -> [NSView] {
        func walk(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)).contains("Passthrough") ? [view] : []) + view.subviews.flatMap(walk)
        }
        return walk(root).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func hostSourceContext<V: View>(_ view: V, size: NSSize) async throws -> NSWindow {
        TypefluxTestApplicationEnvironment.prepare()
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
