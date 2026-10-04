import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import Vision

@Suite("Ask recovery rendering", .serialized)
@MainActor
struct AskRecoveryRenderTests {
    @Test func `uncertain results show helpful decisions without execution internals`() async throws {
        let fixture = try AskTestFixture(), value = AskRecoveryFixture.conversation()
        var audit = AskRecoveryFixture.audit(value)
        audit.toolName = "browser"
        _ = try await fixture.cache.claimExecution(audit, owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        defer { fixture.model.resetSession() }

        for dark in [false, true] {
            let card = AskRecoveryCard(
                presentation: fixture.model.recoveryPresentation,
                inspect: { fixture.model.inspectingRecovery = true }
            )
            let text = try render(card.padding(24), name: "unknown-\(dark ? "dark" : "light")", dark: dark)
            #expect(text.contains(localized("ask.recovery.unknown")))
            #expect(text.contains(localized("ask.recovery.inspect")))
            #expect(!text.contains(localized("ask.recovery.retransmit")))
            #expect(!text.contains(localized("ask.recovery.continue")))
            card.inspect()
            #expect(fixture.model.inspectingRecovery)
        }

        let text = try render(AskRecoveryInspector(model: fixture.model), name: "inspect-unknown")
        #expect(text.contains(localized("ask.recovery.checkBody")))
        #expect(text.contains(localized("ask.recovery.end")))
        #expect(!text.contains("browser"))
        #expect(!text.contains("private"))
        #expect(!text.contains("approval"))
        #expect(!text.contains(String(audit.argumentsHash.prefix(12))))

        if ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SCREENSHOTS"] != nil {
            try renderInspectorChinese(fixture.model, name: "inspect-unknown")
        }

        await fixture.model.endRecoveryRun()
        #expect(fixture.model.selected?.run?.status == "cancelled")
        let ended = try render(AskRecoveryInspector(model: fixture.model), name: "inspect-ended")
        #expect(ended.contains(localized("ask.recovery.newRequest")))
        #expect(!ended.contains(localized("ask.recovery.end")))
        if ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SCREENSHOTS"] != nil {
            try renderInspectorChinese(fixture.model, name: "inspect-ended")
        }
        let feedback = L("ask.recovery.newRequestBody")
        fixture.model.prepareRecoveryRequest()
        #expect(fixture.model.commandFeedback == feedback)
        #expect(!fixture.model.inspectingRecovery)
    }

    @Test func `saved results and paused tasks show only their relevant action`() throws {
        let value = AskRecoveryFixture.conversation()
        let entry = AskExecutionEntry(id: "run/call", audit: AskRecoveryFixture.audit(value),
                                      receipt: AskRecoveryFixture.receipt(value))
        let saved = AskRecoveryPresentation(run: value.run, entries: [entry], deviceId: "device", local: false)
        let synced = try render(
            AskRecoveryCard(presentation: saved, canRetransmit: true).padding(24),
            name: "saved"
        )
        #expect(synced.contains(localized("ask.recovery.saved")))
        #expect(synced.contains(localized("ask.recovery.retransmit")))
        #expect(!synced.contains(localized("ask.recovery.inspect")))
        #expect(!synced.contains(localized("ask.recovery.continue")))

        let paused = AskRecoveryPresentation(run: value.run, entries: [], deviceId: "device", local: true)
        let continued = try render(
            AskRecoveryCard(presentation: paused, canContinue: true).padding(24),
            name: "paused"
        )
        #expect(continued.contains(localized("ask.recovery.paused")))
        #expect(continued.contains(localized("ask.recovery.continue")))
        #expect(!continued.contains(localized("ask.recovery.inspect")))
        #expect(!continued.contains(localized("ask.recovery.retransmit")))

        if ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SCREENSHOTS"] != nil {
            try render(
                AskRecoveryCard(presentation: saved, canRetransmit: true).padding(24),
                name: "saved-zh",
                language: .simplifiedChinese
            )
            try render(
                AskRecoveryCard(presentation: paused, canContinue: true).padding(24),
                name: "paused-zh",
                language: .simplifiedChinese
            )
            let unknown = AskRecoveryPresentation(run: value.run,
                                                  entries: [.init(id: entry.id, audit: entry.audit, receipt: nil)],
                                                  deviceId: "device", local: true)
            try render(
                AskRecoveryCard(presentation: unknown).padding(24),
                name: "unknown-zh",
                language: .simplifiedChinese
            )
        }
    }

    @Test func `completed conversation contains the answer without a recovery notice`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        value.title = "Plan for the week"
        value.messages = [
            .init(id: "question", role: "user", text: "Help me plan this week.", createdAt: Date()),
            .init(
                id: "answer",
                role: "assistant",
                text: "Start with the release checklist, then prepare the demo.",
                createdAt: Date()
            )
        ]
        value.run?.status = "completed"
        value.run?.pending = []
        let audit = AskRecoveryFixture.audit(value)
        _ = try await fixture.cache.claimExecution(audit, owner: "owner")
        try await fixture.cache.saveReceipt(AskRecoveryFixture.receipt(value), identity: audit.identity, owner: "owner")
        try await fixture.cache.recordExecution(id: "run/call", event: .acknowledged, owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.refreshHistory()
        await fixture.model.select(value.id)
        #expect(!fixture.model.hasRecoveryNotice)

        let empty = try render(VStack {
            Text("Ready")
            AskRecoveryCard(presentation: fixture.model.recoveryPresentation)
        }, name: "completed-card-hidden")
        #expect(empty == "Ready")

        let text = try await renderConversation(fixture.model, name: "completed-chat", size: .init(
            width: 1100,
            height: 740
        ))
        #expect(text.contains("release checklist"))
        #expect(!text.contains(localized("ask.recovery.inspect")))
        #expect(!text.contains(localized("ask.recovery.saved")))
        #expect(!text.contains(localized("ask.recovery.paused")))
        #expect(!text.contains("Conversation history restored"))

        if ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SCREENSHOTS"] != nil {
            try await renderCompletedChinese(fixture, conversation: value)
        }
    }

    private func renderCompletedChinese(_ fixture: AskTestFixture, conversation: AskConversation) async throws {
        var value = conversation
        value.title = "梳理本周计划"
        value.messages = [
            .init(id: "question", role: "user", text: "帮我梳理这周最值得先做的三件事。", createdAt: Date()),
            .init(id: "answer", role: "assistant", text: "建议先锁定发布范围，再走通真实使用流程，最后准备验收检查表。", createdAt: Date())
        ]
        value.revision += 1
        await fixture.api.seed(value)
        await fixture.model.refreshHistory()
        await fixture.model.select(value.id, reload: true)
        try await renderConversation(
            fixture.model,
            name: "completed-chat-zh",
            language: .simplifiedChinese,
            size: .init(
                width: 1100,
                height: 740
            )
        )
    }

    @Test func `uncertain stopped task has one clear decision without retry or continue`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        value.title = "Update the weekly plan"
        value.messages[0].text = "Update my weekly plan."
        value.run?.status = "cancelled"
        _ = try await fixture.cache.claimExecution(AskRecoveryFixture.audit(value), owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        fixture.model.error = localized("ask.recovery.unknownBody")
        let text = try await renderConversation(fixture.model, name: "unknown-stopped-chat", size: .init(
            width: 1100,
            height: 740
        ))
        #expect(text.components(separatedBy: localized("ask.recovery.unknown")).count == 2)
        #expect(text.components(separatedBy: localized("ask.recovery.inspect")).count == 2)
        #expect(!text.contains(localized("ask.retry")))
        #expect(!text.contains(localized("ask.resume")))

        if ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SCREENSHOTS"] != nil {
            value.title = "更新本周计划"
            value.messages[0].text = "帮我更新本周计划。"
            value.revision += 1
            await fixture.api.seed(value)
            await fixture.model.refreshHistory()
            await fixture.model.select(value.id, reload: true)
            fixture.model.error = localized("ask.recovery.unknownBody", language: .simplifiedChinese)
            for (name, dark, width) in [
                ("unknown-stopped-chat-zh", false, 1100.0),
                ("unknown-stopped-chat-dark-zh", true, 1100.0),
                ("unknown-stopped-chat-narrow-zh", false, 360.0)
            ] {
                let chinese = try await renderConversation(
                    fixture.model,
                    name: name,
                    dark: dark,
                    language: .simplifiedChinese,
                    size: .init(width: width, height: width == 360 ? 640 : 740)
                )
                #expect(readable(chinese).contains(readable(localized("ask.recovery.unknown",
                                                                      language: .simplifiedChinese))))
                #expect(readable(chinese).contains(readable(localized("ask.recovery.inspect",
                                                                      language: .simplifiedChinese))))
            }
        }
    }

    @Test func `recovery guidance is localized in every supported language`() throws {
        let keys = ["unknown", "unknownBody", "checkBody", "endBody", "binding", "otherDevice", "saved", "savedBody",
                    "paused", "activeBody", "finished", "finishedBody", "inspect", "retransmit", "continue", "close",
                    "end", "newRequest", "newRequestBody"].map { "ask.recovery." + $0 }
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let text = bundle.localizedString(forKey: key, value: nil, table: nil)
                #expect(text != key && !text.isEmpty, "Missing \(key) in \(language.rawValue)")
                for term in ["receipt", "回执", "回執", "toolVersion", "argumentsHash", "operationId"] {
                    #expect(!text.contains(term), "Internal term in \(key) for \(language.rawValue)")
                }
            }
        }
    }
}

extension AskRecoveryRenderTests {
    @Test func `narrow recovery cards keep guidance and actions readable`() throws {
        let value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        let savedEntry = AskExecutionEntry(id: "run/call", audit: audit, receipt: AskRecoveryFixture.receipt(value))
        let unknownEntry = AskExecutionEntry(id: "run/call", audit: audit, receipt: nil)
        let unknown = AskRecoveryPresentation(run: value.run, entries: [unknownEntry], deviceId: "device", local: true)
        let saved = AskRecoveryPresentation(run: value.run, entries: [savedEntry], deviceId: "device", local: true)
        let paused = AskRecoveryPresentation(run: value.run, entries: [], deviceId: "device", local: true)
        let cases = [
            NarrowCase(
                name: "unknown",
                card: AskRecoveryCard(presentation: unknown),
                actionKey: "ask.recovery.inspect"
            ),
            NarrowCase(name: "saved", card: AskRecoveryCard(presentation: saved, canRetransmit: true),
                       actionKey: "ask.recovery.retransmit"),
            NarrowCase(
                name: "saved-working",
                card: AskRecoveryCard(presentation: saved, canRetransmit: true, working: true),
                actionKey: "ask.recovery.retransmit"
            ),
            NarrowCase(name: "paused", card: AskRecoveryCard(presentation: paused, canContinue: true),
                       actionKey: "ask.recovery.continue")
        ]
        for language in [AppLanguage.english, .simplifiedChinese] {
            for item in cases {
                let text = try render(
                    item.card.padding(12),
                    name: "\(item.name)-narrow-\(language == .english ? "en" : "zh")",
                    language: language,
                    size: .init(width: 340, height: 360)
                )
                for key in [item.card.presentation.titleKey, item.card.presentation.bodyKey, item.actionKey] {
                    #expect(readable(text).contains(readable(localized(key, language: language))),
                            "Missing or clipped \(key) in \(item.name), \(language.rawValue): \(text)")
                }
            }
        }
    }

    @Test func `narrow inspector keeps complete guidance and footer actions readable`() async throws {
        let fixture = try AskTestFixture(), value = AskRecoveryFixture.conversation()
        _ = try await fixture.cache.claimExecution(AskRecoveryFixture.audit(value), owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        defer { fixture.model.resetSession() }

        for active in [true, false] {
            if !active {
                await fixture.model.endRecoveryRun()
            }
            for language in [AppLanguage.english, .simplifiedChinese] {
                let text = try render(
                    AskRecoveryInspector(model: fixture.model).frame(width: 360),
                    name: "inspect-\(active ? "active" : "ended")-narrow-\(language == .english ? "en" : "zh")",
                    language: language,
                    size: .init(width: 360, height: 560)
                )
                let keys = ["ask.recovery.unknown", "ask.recovery.unknownBody", "ask.recovery.checkBody",
                            active ? "ask.recovery.endBody" : "ask.recovery.newRequestBody",
                            active ? "ask.recovery.end" : "ask.recovery.newRequest", "ask.recovery.close"]
                for key in keys {
                    #expect(readable(text).contains(readable(localized(key, language: language))),
                            "Missing or clipped \(key) in inspector, \(language.rawValue): \(text)")
                }
            }
        }
    }

    private struct NarrowCase {
        let name: String
        let card: AskRecoveryCard
        let actionKey: String
    }

    private func renderInspectorChinese(_ model: AskConversationModel, name: String) throws {
        for dark in [false, true] {
            let text = try render(
                AskRecoveryInspector(model: model),
                name: "\(name)-\(dark ? "dark-" : "")zh",
                dark: dark,
                language: .simplifiedChinese,
                size: .init(width: 560, height: 560)
            )
            let actionKey = model.recoveryPresentation.active ? "ask.recovery.end" : "ask.recovery.newRequest"
            for key in [model.recoveryPresentation.titleKey, "ask.recovery.checkBody", actionKey] {
                #expect(readable(text).contains(readable(localized(key, language: .simplifiedChinese))))
            }
        }
    }

    private func readable(_ text: String) -> String {
        // OCR inserts spaces between wrapped lines and Chinese words. Ignore those
        // differences while still requiring every word of the guidance and action.
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }

    private func localized(_ key: String, language: AppLanguage = .english) -> String {
        let bundle = language.bundleLocalizationCandidates.compactMap {
            Bundle.module.path(forResource: $0, ofType: "lproj").flatMap(Bundle.init(path:))
        }.first ?? Bundle.module
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    @discardableResult
    private func renderConversation(_ model: AskConversationModel, name: String, dark: Bool = false,
                                    language: AppLanguage = .english, size: NSSize) async throws -> String {
        func content() -> some View {
            AskConversationView(model: model)
                .environment(\.askGlassMaterialOverride, .opaque)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(AskTheme.surface)
        }
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: content())
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        // The transcript reveals after two queued scroll-restoration passes.
        // Do not own the global language or window focus while those passes run.
        try await Task.sleep(for: .milliseconds(400))
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(language)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        hosting.rootView = content()
        model.objectWillChange.send()
        return try snapshot(hosting, name: name, language: language)
    }

    @discardableResult
    private func render(_ view: some View, name: String, dark: Bool = false,
                        language: AppLanguage = .english,
                        size: NSSize = .init(width: 650, height: 480)) throws -> String {
        // Keep global localization changes inside one MainActor job. Other test
        // suites can change the language or window focus whenever an async test yields.
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(language)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        defer { window.close() }
        return try snapshot(hosting, name: name, language: language)
    }

    private func snapshot(_ hosting: NSView, name: String, language: AppLanguage) throws -> String {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        // Explicit Retina density keeps small native labels legible both in the
        // exported fixtures and to Vision, independent of the runtime display.
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(hosting.bounds.width * 2),
            pixelsHigh: Int(hosting.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SCREENSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent(name + ".png"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Vision prioritizes the first language; English-first recognition misses
        // entire Chinese labels even when zh-Hans is present as a fallback.
        request.recognitionLanguages = language == .simplifiedChinese ? ["zh-Hans", "en-US"] : ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
