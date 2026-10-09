import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask selected references", .serialized, .exclusiveUIState)
@MainActor
struct AskReferenceTests {
    private func reference(question: String = "Why?") -> AskReference {
        AskReference(messageId: UUID().uuidString, text: "A selected sentence 🦆", question: question)
    }

    @Test func optionalQuestionAndMainQuestionControlSending() {
        var draft = AskDraft.followUp
        draft.references = [reference(question: " \n")]
        #expect(!draft.canSend)
        draft.text = "Explain both"
        #expect(draft.canSend)
        draft.text = ""
        draft.references?.append(reference())
        #expect(draft.canSend)
        let request = draft.request(deviceId: "device", tools: [])
        #expect(request.text.isEmpty)
        #expect(request.references == draft.references)
        #expect(request.selection == nil)
    }

    @Test func preservesDraftAndWireFormatWithoutChangingLegacyData() async throws {
        let f = try AskTestFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var draft = AskDraft.followUp
        draft.references = [reference(), reference(question: "")]
        try await f.cache.saveDraft(draft, key: "chat", owner: "owner")
        #expect(try await f.cache.draft(key: "chat", owner: "owner") == draft)
        let data = try AskCoding.encoder().encode(draft.request(deviceId: "device", tools: []))
        #expect(String(decoding: data, as: UTF8.self).contains("message_id"))
        #expect(try AskCoding.decoder().decode(AskSendRequest.self, from: data).references == draft.references)
        let legacy = Data(#"{"text":"hello","include_screenshot":false}"#.utf8)
        #expect(try AskCoding.decoder().decode(AskDraft.self, from: legacy).references == nil)
        let oldMessage = Data(#"{"id":"old","role":"user","text":"hello","created_at":"2026-09-30T00:00:00Z"}"#.utf8)
        #expect(try AskCoding.decoder().decode(AskMessage.self, from: oldMessage).references == nil)
    }

    @Test func limitsCountAndUTF8SizeWithoutDroppingDraft() throws {
        let f = try AskTestFixture()
        for _ in 0..<32 { f.model.addReference(reference()) }
        #expect(f.model.draft.references?.count == 32)
        f.model.addReference(reference())
        #expect(f.model.draft.references?.count == 32)
        #expect(f.model.error != nil)
        var draft = AskDraft.followUp
        draft.references = [AskReference(messageId: "source", text: String(repeating: "中", count: 21333))]
        #expect(draft.referencesWithinLimit)
        draft.references?[0].question = "ab"
        #expect(!draft.referencesWithinLimit)
        #expect(AskDraft.followUp.referencesWithinLimit)
    }

    @Test func usageOnlySnapshotKeepsOptimisticReferences() {
        let ref = reference()
        let message = AskMessage(id: UUID().uuidString, role: "user", text: "", createdAt: Date(), references: [ref])
        let optimistic = AskConversation(id: UUID().uuidString, title: "Test", revision: 3, updatedAt: Date(), messages: [message])
        var incoming = optimistic
        incoming.messages = []
        incoming.usage = AskConversationUsage(version: 2, since: Date(), historicalGap: false, total: AskUsageTotals(), runs: [:])
        let reconciled = optimistic.reconciling(incoming, preservingEqualRevisionContent: true)
        #expect(reconciled.messages == [message])
        #expect(reconciled.usage == incoming.usage)
        incoming.revision = 4
        #expect(optimistic.reconciling(incoming, preservingEqualRevisionContent: true).messages.isEmpty)
    }

    @Test func submissionAndRetryKeepReferences() async throws {
        let f = try AskTestFixture()
        f.model.draft.text = "Initial question"
        f.model.submitDraft()
        try await f.wait { !f.model.isBusy }
        let source = try #require(f.model.selected?.messages.last)
        let ref = AskReference(messageId: source.id, text: "the answer", question: "Explain this")
        f.model.addReference(ref)
        #expect(f.model.canSend)
        await f.api.setFailSend(true)
        f.model.submitDraft()
        try await f.wait { !f.model.isBusy }
        #expect(f.model.selected?.messages.last?.references == [ref])
        #expect(f.model.draft.references == nil)
        await f.api.setFailSend(false)
        f.model.resume()
        try await f.wait { !f.model.isBusy }
        #expect(await f.api.sends.last?.references == [ref])
        #expect(f.model.selected?.messages.dropLast().last?.references == [ref])
        f.model.resetSession()
    }

    @Test func nativeSelectionUsesRenderedUTF16RangeAndPreservesCopy() {
        let editor = AskTranscriptText.Editor()
        editor.setContent("**Hello** 🦆\n\nSecond paragraph", markdown: true, dark: false)
        let range = (editor.string as NSString).range(of: "🦆\nSecond")
        #expect(range.location != NSNotFound)
        editor.setSelectedRange(range)
        #expect(editor.selectedExcerpt == "🦆\nSecond")
        editor.setContent("**Hello** 🦆\n\nSecond paragraph grows", markdown: true, dark: false)
        #expect(editor.selectedExcerpt == "🦆\nSecond")
        editor.showSelectionAction()
        #expect(editor.selectedRange() == range)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.selectedExcerpt == nil)
        editor.setContent(" \n", markdown: false, dark: false)
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        #expect(editor.selectedExcerpt == nil)
    }

    @Test func selectionActionsResolveInOneClickWithoutAModal() async throws {
        _ = NSApplication.shared
        let editor = AskTranscriptText.Editor(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        editor.isEditable = false
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.orderFront(nil)
        defer { editor.askPopover.close(); window.close() }
        var added: [(String, String)] = []
        editor.onAsk = { text, question in added.append((text, question)) }
        editor.setContent("First **sentence**. Second sentence.", markdown: true, dark: false)
        editor.setSelectedRange((editor.string as NSString).range(of: "sentence"))

        // The bar appears on selection and, on its own, changes nothing.
        editor.showSelectionAction()
        #expect(editor.askPopover.isShown)
        #expect(added.isEmpty)

        // Explain and translate carry a ready-made question; Ask leaves it open.
        editor.perform(.explain, excerpt: "sentence")
        #expect(!editor.askPopover.isShown)
        #expect(added.count == 1)
        #expect(added[0].0 == "sentence")
        #expect(added[0].1 == L("ask.references.explain"))

        editor.showSelectionAction()
        editor.perform(.translate, excerpt: "sentence")
        #expect(added[1].0 == "sentence")
        #expect(added[1].1 == L("ask.references.translate"))

        editor.showSelectionAction()
        editor.perform(.ask, excerpt: "sentence")
        #expect(added[2].0 == "sentence")
        #expect(added[2].1.isEmpty)

        // Copy never reaches the composer, it only fills the pasteboard.
        NSPasteboard.general.clearContents()
        editor.showSelectionAction()
        editor.perform(.copy, excerpt: "sentence")
        #expect(added.count == 3)
        #expect(NSPasteboard.general.string(forType: .string) == "sentence")
        #expect(!editor.askPopover.isShown)

        // Without a handler the bar never opens, so a streaming answer stays inert.
        editor.onAsk = nil
        editor.showSelectionAction()
        #expect(!editor.askPopover.isShown)
    }

    @Test func selectionActionsCarryDistinctTitlesAndQuestions() {
        #expect(AskSelectionAction.allCases.count == 4)
        let titles = AskSelectionAction.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        // A missing table entry makes L() echo the key, so guard against that.
        #expect(AskSelectionAction.allCases.allSatisfy { !$0.title.isEmpty && !$0.title.hasPrefix("ask.") })
        #expect(!AskSelectionAction.explain.question.hasPrefix("ask."))
        #expect(!AskSelectionAction.translate.question.hasPrefix("ask."))
        #expect(AskSelectionAction.explain.question == L("ask.references.explain"))
        #expect(AskSelectionAction.translate.question == L("ask.references.translate"))
        #expect(AskSelectionAction.ask.question.isEmpty)
        #expect(AskSelectionAction.copy.question.isEmpty)
        #expect(AskSelectionAction.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }

    @Test func renderReferenceSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_REFERENCE_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = try AskTestFixture()
        let conversationID = UUID().uuidString
        let sourceID = UUID().uuidString
        let source = "## A practical plan\n\nStart with the smallest useful workflow.\n\n- Keep the original context.\n- Test one assumption at a time.\n- Review the result before expanding."
        let quoted = AskReference(messageId: sourceID, text: "Test one assumption at a time.", question: "How would I choose the first assumption?")
        await f.api.seed(AskConversation(id: conversationID, title: "A practical plan", revision: 1, updatedAt: Date(), messages: [
            AskMessage(id: UUID().uuidString, role: "user", text: "Help me plan a small product experiment.", createdAt: Date()),
            AskMessage(id: sourceID, role: "assistant", text: source, createdAt: Date()),
            AskMessage(id: UUID().uuidString, role: "user", text: "", createdAt: Date(), references: [quoted]),
            AskMessage(id: UUID().uuidString, role: "assistant", text: "Start with the assumption that would change your next decision.", createdAt: Date())
        ]))
        await f.model.select(conversationID)
        f.model.draft.text = "How do these suggestions fit together?"
        for _ in 0..<8 {
            var item = quoted
            item.id = UUID().uuidString
            f.model.addReference(item)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = VStack(spacing: 16) {
                AskReferenceEditor(reference: reference(), save: { _ in }, cancel: {})
                AskSentReferences(references: [reference()])
                AskComposer(model: f.model, launcher: false)
            }.padding(24).frame(width: 740).background(AskTheme.surface)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 530), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("references-\(appearance.rawValue).png"))
            #expect(png.count > 10000)
            window.close()
        }
        let workspace = NSHostingView(rootView: AskConversationView(model: f.model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = workspace
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        workspace.layoutSubtreeIfNeeded()
        let bitmap = try #require(workspace.bitmapImageRepForCachingDisplay(in: workspace.bounds))
        workspace.cacheDisplay(in: workspace.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("ask-references-workspace-dark.png"))
        window.close()
        f.model.resetSession()
    }
}
