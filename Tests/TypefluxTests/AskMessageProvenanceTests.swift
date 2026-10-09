import Foundation
import Testing
@testable import Typeflux

@Suite("Ask sent message provenance", .exclusiveUIState)
struct AskMessageProvenanceTests {
    private func message(source: String? = nil, selection: String? = nil, image: String? = nil) -> AskMessage {
        AskMessage(id: "sent-question", role: "user", text: "Explain this", selection: selection,
                   source: source, image: image, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func sentFactsKeepTheirOrderAndFullPreviewContent() {
        let items = AskMessageProvenance.items(for: message(source: "Safari — Example — Page",
                                                           selection: "First line\nSecond line", image: "sent-image"))
        #expect(items == [.source(app: "Safari", detail: "Safari — Example — Page"),
                          .selection("First line\nSecond line"), .screenshot("sent-image")])
        #expect(items.map(\.id) == ["source", "selection", "screenshot"])
    }

    @Test(arguments: [nil, "", "  \n", " — Window title"] as [String?])
    func missingSourceNeverInventsAnApp(source: String?) {
        let items = AskMessageProvenance.items(for: message(source: source, selection: "Selected words"))
        #expect(items == [.selection("Selected words")])
    }

    @Test func sourceAloneStillExplainsTheSentMetadata() {
        #expect(AskMessageProvenance.items(for: message(source: "  Finder  "))
            == [.source(app: "Finder", detail: "Finder")])
    }

    @Test func emptyAttachmentsDoNotCreateAnEmptySummary() {
        #expect(AskMessageProvenance.items(for: message()).isEmpty)
        #expect(AskMessageProvenance.items(for: message(source: "", selection: "", image: "")).isEmpty)
    }

    @Test func removedSourceDoesNotHideIndependentSentAttachments() {
        #expect(AskMessageProvenance.items(for: message(selection: "Text", image: "image"))
            == [.selection("Text"), .screenshot("image")])
    }

    @Test func fileImageAttachmentsAreNotMisrepresentedAsScreenCaptures() {
        var sent = message()
        sent.attachments = [.init(id: "uploaded-photo", kind: .image, name: "Photo.png", image: "photo-data")]
        #expect(AskMessageProvenance.items(for: sent).isEmpty)
    }

    @Test(arguments: ["assistant", "tool", "system"])
    func onlyUserMessagesDescribeCapturedInputs(role: String) {
        var sent = message(source: "Safari", selection: "Text", image: "image")
        sent.role = role
        #expect(AskMessageProvenance.items(for: sent).isEmpty)
    }

    @Test func labelsUseSentLineCountsAndScreenScope() {
        #expect(AskMessageProvenance.Item.source(app: "Safari", detail: "Safari — Page").label
            == L("ask.context.selection.source", "Safari"))
        #expect(AskMessageProvenance.Item.selection("One line").label == L("ask.message.selection.line", 1))
        #expect(AskMessageProvenance.Item.selection("One\nTwo").label == L("ask.message.selection.lines", 2))
        #expect(AskMessageProvenance.Item.screenshot("data").label == L("ask.context.screen.full"))
    }

    @Test(arguments: AppLanguage.allCases)
    func contextActionsAndProvenanceAreLocalized(language: AppLanguage) throws {
        let path = try #require(language.bundleLocalizationCandidates.compactMap {
            Bundle.module.path(forResource: $0, ofType: "lproj")
        }.first)
        let bundle = try #require(Bundle(path: path))
        let formats: [(String, String?)] = [
            ("ask.context.refresh.target", "%@"), ("ask.context.source.previous", nil),
            ("ask.context.source.app", nil), ("ask.context.source.window", nil),
            ("ask.context.source.metadataOnly", nil), ("ask.context.selection.lineCount", "%d"),
            ("ask.context.screen.full", nil), ("ask.context.screen.capturing", nil),
            ("ask.context.screen.failed", nil), ("ask.context.screen.grant", nil),
            ("ask.context.screen.retry", nil), ("ask.context.screenshot.removeHint", nil),
            ("ask.context.restore.source", "%@"), ("ask.context.restore.selection", "%d"),
            ("ask.context.undo", nil), ("ask.context.removed.source", nil),
            ("ask.context.removed.selection", nil), ("ask.context.removed.screenshot", nil),
            ("ask.context.restored.source", nil), ("ask.context.restored.selection", nil),
            ("ask.context.restored.screenshot", nil), ("ask.context.refresh.applied", nil),
            ("ask.context.undo.applied", nil), ("ask.message.selection.line", "%d"),
            ("ask.message.selection.lines", "%d")
        ]
        for (key, placeholder) in formats {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            #expect(value != key && !value.isEmpty, "Missing \(key) for \(language.rawValue)")
            if let placeholder { #expect(value.contains(placeholder), "Missing format value in \(key)") }
        }
    }
}
