import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// GUL-464: content rides with a message as large previews, and chosen skills read as
/// tokens by the words instead of sharing the attachment row.
@Suite("Ask content tiles and skill tokens", .serialized, .exclusiveUIState)
@MainActor
struct AskContentTileTests {
    // MARK: - Tile model

    @Test func imageTileNamesTheFileAndItsSize() {
        let tile = AskContentTileModel.make(AskAttachment(kind: .image, name: "shot.png", byteSize: 2048))
        #expect(tile.style == .image)
        #expect(tile.title == "shot.png")
        #expect(tile.caption == ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file))
        #expect(tile.excerpt == nil && tile.badge == nil)
    }

    @Test func documentTileShowsItsFirstWordsBadgeAndPages() {
        let pdf = AskAttachment(kind: .file, name: "Plan v3.pdf", byteSize: 10, text: "Roadmap\n\n  Q1   goals", pages: 12)
        let tile = AskContentTileModel.make(pdf)
        #expect(tile.style == .document)
        #expect(tile.badge == "PDF")
        #expect(tile.excerpt == "Roadmap Q1 goals", "Whitespace collapses so the page shows words")
        #expect(tile.caption == L("ask.attach.pages", 12), "Pages outrank the byte size")

        let note = AskContentTileModel.make(AskAttachment(kind: .file, name: "notes.md", byteSize: 4096, text: "hi"))
        #expect(note.badge == "MD")
        #expect(note.caption == ByteCountFormatter.string(fromByteCount: 4096, countStyle: .file))
    }

    @Test func folderTileIsReadOnlyAndKeepsItsPath() {
        let tile = AskContentTileModel.make(AskAttachment(kind: .folder, name: "typeflux", path: "/Users/me/typeflux"))
        #expect(tile.style == .folder)
        #expect(tile.caption == L("ask.attach.folderReadOnly"))
        #expect(tile.excerpt == "/Users/me/typeflux")
    }

    @Test func excerptIsBoundedAndEmptyTextHasNone() {
        #expect(AskContentTileModel.excerpt(nil) == nil)
        #expect(AskContentTileModel.excerpt(" \n\t ") == nil)
        let long = String(repeating: "a", count: AskContentTileModel.excerptLimit + 50)
        let excerpt = AskContentTileModel.excerpt(long)
        #expect(excerpt?.count == AskContentTileModel.excerptLimit + 1)
        #expect(excerpt?.hasSuffix("…") == true)
    }

    @Test func badgeFollowsTheExtensionOrPages() {
        #expect(AskContentTileModel.badge(for: "a.docx", pages: nil) == "DOCX")
        #expect(AskContentTileModel.badge(for: "scan", pages: 3) == "PDF")
        #expect(AskContentTileModel.badge(for: "README", pages: nil) == nil)
        #expect(AskContentTileModel.badge(for: "archive.verylongext", pages: nil) == nil)
        #expect(AskContentTileModel.sizeCaption(nil) == nil)
        #expect(AskContentTileModel.sizeCaption(0) == nil)
    }

    @Test func badgeColorsSeparateFamilies() {
        let colors = ["PDF", "XLSX", "DOCX", "MD", "ZIP"].map { AskContentTileModel.badgeColor($0).description }
        #expect(Set(colors).count == colors.count)
        #expect(AskContentTileModel.badgeColor(nil).description == AskContentTileModel.badgeColor("ZIP").description)
    }

    @Test func contextItemsBecomeImagePendingWarningOrQuoteTiles() {
        let attached = AskContextItem(kind: .screenshot, systemImage: "display", style: .neutral,
                                      title: "Screen", detail: "Whole screen")
        #expect(AskContentTileModel.make(attached).style == .image)
        #expect(AskContentTileModel.make(attached, capturing: true).style == .pending)

        let failed = AskContextItem(kind: .screenshot, systemImage: "exclamationmark.triangle", style: .warning,
                                    title: "Failed", detail: "Allow recording")
        let warning = AskContentTileModel.make(failed)
        #expect(warning.style == .warning && warning.caption == "Allow recording")
        let unavailable = AskContextItem(kind: .screenshot, systemImage: "x", style: .unavailable, title: "No")
        #expect(AskContentTileModel.make(unavailable).style == .warning)

        let selection = AskContextItem(kind: .selection, systemImage: "text.alignleft", style: .neutral,
                                       title: "“short”", detail: "line one\nline two", sourceAppName: "Safari")
        let quote = AskContentTileModel.make(selection)
        #expect(quote.style == .selection)
        #expect(quote.title == "Safari")
        #expect(quote.excerpt == "line one line two")

        let source = AskContextItem(kind: .source, systemImage: "app", style: .neutral, title: "Safari", detail: "Docs")
        #expect(AskContentTileModel.make(source).style == .document)
    }

    @Test func onlyAnUncompressedWorkspaceUsesTiles() {
        #expect(AskComposerLayout.usesContentTiles(launcher: false, compact: false))
        #expect(!AskComposerLayout.usesContentTiles(launcher: true, compact: false))
        #expect(!AskComposerLayout.usesContentTiles(launcher: false, compact: true))
    }

    // MARK: - "+" menu skills

    private let skills = [AskSkillSummary(name: "email-reply", description: "Reply to mail", builtin: true),
                          AskSkillSummary(name: "pdf-reader", description: "Read PDFs", builtin: false),
                          AskSkillSummary(name: "translate", description: "Translate", builtin: true)]

    @Test func skillsSummarySaysWhatIsChosenOrThatSkillsApplyOnTheirOwn() {
        var context = AskAddMenuContext(skills: skills)
        #expect(context.skillsSummary == L("ask.add.skills.auto", 3))
        context.chosenSkills = ["email-reply", "translate"]
        #expect(context.skillsSummary == L("ask.add.skills.chosen", "email-reply, translate"))
    }

    @Test func aFullChoiceOnlyAllowsRemoving() {
        let context = AskAddMenuContext(skills: skills, chosenSkills: ["email-reply"], skillLimit: 1)
        #expect(context.canChoose(skills[0]), "A chosen skill can always be removed")
        #expect(!context.canChoose(skills[1]))
    }

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 420, height: 560)) -> NSWindow {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height,
                                                                 alignment: .bottomLeading))
        window.orderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 15 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func find(_ identifier: String, in window: NSWindow) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> NSObject? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier { return object }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }

    private func press(_ identifier: String, in window: NSWindow) throws {
        let element = try #require(find(identifier, in: window), "Missing \(identifier)")
        _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
    }

    @Test func skillsRowOpensAPageThatTogglesSkills() async throws {
        var toggled: [String] = []
        let context = AskAddMenuContext(skills: skills, chosenSkills: ["translate"], toggleSkill: { toggled.append($0) })
        let window = host(AskComposerAddMenu(context: context, pickFiles: {}))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.add.skill.email-reply", in: window) == nil, "Skills wait on their own page")
        try press("ask.add.skills", in: window)
        try await settle(window)
        #expect(find("ask.add.files", in: window) == nil)
        try press("ask.add.skill.email-reply", in: window)
        try press("ask.add.skill.translate", in: window)
        #expect(toggled == ["email-reply", "translate"])
        try press("ask.add.skills.back", in: window)
        try await settle(window)
        #expect(find("ask.add.files", in: window) != nil)
    }

    @Test func menuWithoutSkillsHasNoSkillsRow() async throws {
        let window = host(AskComposerAddMenu(context: AskAddMenuContext(), pickFiles: {}))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.add.files", in: window) != nil)
        #expect(find("ask.add.skills", in: window) == nil)
    }

    // MARK: - Model

    @Test func toggleSkillChoosesRemovesAndRespectsTheLimit() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.toggleSkill("a", launcher: false)
        model.toggleSkill("b", launcher: false)
        #expect(model.draft.skills == ["a", "b"])
        model.toggleSkill("a", launcher: false)
        #expect(model.draft.skills == ["b"])
        model.toggleSkill("b", launcher: false)
        #expect(model.draft.skills == nil, "No choice is stored as nil")
        for name in ["a", "b", "c", "d"] { model.toggleSkill(name, launcher: false) }
        #expect(model.draft.skills?.count == AskConversationModel.maximumChosenSkills)
        model.toggleSkill("x", launcher: true)
        #expect(model.launcherDraft.skills == ["x"])
    }

    @Test func installedSkillsMarkBuiltInOnes() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.commandSources.skills = {
            [AskSkill(name: "email-reply", description: "Reply", body: ""),
             AskSkill(name: "mine", description: "Mine", body: "")]
        }
        fixture.model.commandSources.builtinSkillNames = { ["email-reply"] }
        let skills = fixture.model.installedSkills()
        #expect(skills.map(\.name) == ["email-reply", "mine"])
        #expect(skills.map(\.builtin) == [true, false])
        #expect(fixture.model.installedSkills(builtins: []).allSatisfy { !$0.builtin })
    }

    // MARK: - Composer integration

    @Test func workspaceShowsLargePreviewsAndSkillTokens() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.draft.attachments = [AskAttachment(kind: .file, name: "plan.pdf", text: "Roadmap", pages: 2)]
        fixture.model.draft.skills = ["email-reply"]
        let window = host(AskComposer(model: fixture.model, launcher: false), size: NSSize(width: 760, height: 360))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.content.attachment", in: window) != nil)
        #expect(find("ask.composer.tokens", in: window) != nil)
        #expect(find("ask.composer.token.skill:email-reply", in: window) != nil)
    }

    @Test func launcherKeepsSkillsAsChipsWithoutTokens() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft.skills = ["email-reply"]
        let window = host(AskComposer(model: fixture.model, launcher: true), size: NSSize(width: 760, height: 360))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.composer.tokens", in: window) == nil)
    }

    @Test func stripTilesShowScreenshotAttachmentsAndLoading() async throws {
        let screenshot = AskContextItem(kind: .screenshot, systemImage: "display", style: .neutral,
                                        title: "Screen", detail: "Whole screen", removable: true)
        let source = AskContextItem(kind: .source, systemImage: "app", style: .neutral, title: "Safari",
                                    detail: "Docs", removable: true)
        let view = AskAttachmentStripView(
            items: [source, screenshot], screenshot: NSImage(size: NSSize(width: 8, height: 5)),
            onPreview: {}, onRemove: { _ in },
            attachments: [AskAttachment(id: "img", kind: .image, name: "a.png")],
            loading: true, onRemoveAttachment: { _ in }, tiles: true)
        let window = host(view, size: NSSize(width: 640, height: 200))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.content.screenshot.tile", in: window) != nil)
        #expect(find("ask.content.attachment", in: window) != nil)
        #expect(find("ask.content.source.preview", in: window) != nil, "Source metadata keeps its chip")
    }

    @Test func tokensAndTilesRenderOnTheirOwn() async throws {
        let tools = [AskChosenTool(kind: .skill, name: "email-reply"), AskChosenTool(kind: .mcpServer, name: "github")]
        let window = host(VStack {
            AskChosenToolTokens(tools: tools) { _ in }
            AskChosenToolToken(tool: tools[0])
            AskContentTile(tile: AskContentTileModel(style: .warning, title: "Failed", caption: "Why"),
                           actionLabel: "Retry", onAction: {})
            AskContentTile(tile: AskContentTileModel(style: .pending, title: "Capturing"))
            AskContentTile(tile: AskContentTileModel(style: .selection, title: "Safari", excerpt: "Quoted"))
            AskContentTile(tile: AskContentTileModel(style: .folder, title: "src", caption: "Read-only"))
            AskContentTile(tile: AskContentTileModel(style: .image, title: "Screen"), screen: true)
        }, size: NSSize(width: 520, height: 900))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.composer.token.skill:email-reply", in: window) != nil)
        #expect(find("ask.composer.token.mcpServer:github", in: window) != nil)
        #expect(find("ask.content.screenshot.action", in: window) != nil)
        #expect(AskChosenToolToken.tint(.skill) != AskChosenToolToken.tint(.mcpServer))
    }
}
