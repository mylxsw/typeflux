import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct VocabularyHistorySettingsTests {
    private typealias RenderedUI = SettingsBehaviorTestSupport

    @Test func `new word stays accessible in a narrow populated vocabulary window`() async throws {
        try await withModel(section: .vocabulary) { model, _ in
            model.addVocabularyTerm("Existing term")
            try await TypefluxNavigationTestSupport.withWindow(
                StudioView(viewModel: model), size: NSSize(width: 900, height: 600)
            ) { window, _ in
                try await RenderedUI.wait("New word button in the narrow populated toolbar") {
                    RenderedUI.elements(in: window).contains {
                        [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.radioButton.rawValue].contains($0.role)
                            && $0.label == L("vocabulary.action.newWord")
                    }
                }
                try RenderedUI.button(L("vocabulary.action.newWord"), in: window).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                try await RenderedUI.wait { RenderedUI.contains(L("common.cancel"), in: sheet) }
                try RenderedUI.button(L("common.cancel"), in: sheet).press()
                try await RenderedUI.wait { window.attachedSheet == nil }
                #expect(model.vocabularyEntries.map(\.term) == ["Existing term"])
            }
        }
    }

    @Test func `empty search adds the query through a sheet and keyboard dismissal works`() async throws {
        try await withModel(section: .vocabulary) { model, _ in
            try await TypefluxNavigationTestSupport.withWindow(
                StudioView(viewModel: model).frame(width: 1680, height: 820),
                size: NSSize(width: 1680, height: 820)
            ) { window, host in
                model.searchQuery = "NewTerm"
                try await RenderedUI.wait { RenderedUI.contains(L("vocabulary.action.addQuery", "NewTerm"), in: host) }
                try RenderedUI.button(L("vocabulary.action.addQuery", "NewTerm"), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                try await RenderedUI.wait { RenderedUI.contains(L("vocabulary.sheet.title"), in: sheet) }
                try await RenderedUI.wait { sheet.firstResponder is NSTextView }
                try RenderedUI.button(L("vocabulary.action.addWord"), in: sheet).press()
                try await RenderedUI.wait { model.vocabularyEntries.contains { $0.term == "NewTerm" } }
                #expect(model.searchQuery.isEmpty)
                try await RenderedUI.wait { window.attachedSheet == nil }
                try RenderedUI.button(L("vocabulary.action.newWord"), in: window).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                let cancelSheet = try #require(window.attachedSheet)
                try TypefluxNavigationTestSupport.sendKey(53, to: cancelSheet, keyEquivalent: true)
                try await RenderedUI.wait { window.attachedSheet == nil }
                #expect(model.vocabularyEntries.count == 1)
            }
        }
    }

    @Test func `source selection filters the native table and selected rows expose edit copy delete`() async throws {
        try await withModel(section: .vocabulary) { model, _ in
            model.addVocabularyTerm("ManualTerm")
            model.addVocabularyTerm("AutomaticTerm", source: .automatic)
            model.addVocabularyTerm("ClaudeTerm", source: .claude)
            try await TypefluxNavigationTestSupport.withWindow(
                StudioView(viewModel: model).frame(width: 1440, height: 820),
                size: NSSize(width: 1440, height: 820)
            ) { window, host in
                try await RenderedUI.wait { RenderedUI.contains("ManualTerm", in: host) }
                try RenderedUI.button(VocabularyFilter.automatic.title, in: window).press()
                try await RenderedUI.wait { !RenderedUI.contains("ManualTerm", in: host) }
                #expect(RenderedUI.contains("AutomaticTerm", in: host))
                try RenderedUI.button(VocabularyFilter.otherApps.title, in: window).press()
                try await RenderedUI.wait { RenderedUI.contains("ClaudeTerm", in: host) }
                #expect(!RenderedUI.contains("AutomaticTerm", in: host))
                try RenderedUI.button(VocabularyFilter.all.title, in: window).press()
                try await RenderedUI.wait { RenderedUI.contains("ManualTerm", in: host) }
                let table = try vocabularyTable(in: host)
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                try await RenderedUI.wait { RenderedUI.elements(in: host).contains { $0.label == L("common.edit") } }
                try RenderedUI.button(L("common.copy"), in: host).press()
                #expect(model.vocabularyEntries.contains { $0.term == NSPasteboard.general.string(forType: .string) })
                try RenderedUI.button(L("common.edit"), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                try await RenderedUI.wait { RenderedUI.contains(L("vocabulary.sheet.editTitle"), in: sheet) }
                try RenderedUI.button(L("common.save"), in: sheet).press()
                try await RenderedUI.wait { window.attachedSheet == nil }
                #expect(model.vocabularyEntries.count == 3)
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                try await RenderedUI.wait { RenderedUI.elements(in: host).contains { $0.label == L("common.delete") } }
                try RenderedUI.button(L("common.delete"), in: host).press()
                try await RenderedUI.wait { model.vocabularyEntries.count == 2 }
                try await deleteFromKeyboard(window: window, host: host)
                try await RenderedUI.wait { model.vocabularyEntries.count == 1 }
            }
        }
    }

    @Test func `history search filter navigation and deletion preserve a complete list`() async throws {
        try await withModel(section: .history) { model, store in
            let failed = HistoryRecord(date: Date(), transcriptText: "Failed Alpha", personaPrompt: "Be concise",
                                       personaResultText: "Alpha result", openCCResultText: "Alpha converted",
                                       openCCConfig: "s2tw", postProcessedText: "Alpha final",
                                       selectionOriginalText: "before", selectionEditedText: "after",
                                       errorMessage: "Fixture error", applyMessage: "Fixture insertion status")
            let successful = HistoryRecord(date: Date().addingTimeInterval(-86400), transcriptText: "Beta result")
            store.save(record: failed)
            store.save(record: successful)
            model.navigate(to: .history)
            try await RenderedUI.wait { model.displayedHistory.count == 2 }
            #expect(model.groupedHistory.count == 2)
            try await TypefluxNavigationTestSupport.withWindow(
                StudioView(viewModel: model).frame(width: 1680, height: 820),
                size: NSSize(width: 1680, height: 820)
            ) { window, host in
                try RenderedUI.button("Alpha final", in: host).press()
                try await RenderedUI.wait { RenderedUI.contains(L("history.detail.rawTranscript"), in: host) }
                #expect(RenderedUI.contains("Be concise", in: host))
                #expect(RenderedUI.contains("Fixture error", in: host))
                try RenderedUI.button(L("history.action.back"), in: window).press()
                try await RenderedUI.wait { !RenderedUI.contains(L("history.detail.rawTranscript"), in: host) }
                try RenderedUI.button("Alpha final", in: host).press()
                try await RenderedUI.wait { RenderedUI.contains(L("history.detail.rawTranscript"), in: host) }
                model.deleteHistoryRecord(id: failed.id)
                try await RenderedUI.wait { !RenderedUI.contains("Alpha final", in: host) }
                #expect(store.record(id: failed.id) == nil)
                model.historyFilter = .failures
                try await RenderedUI.wait { model.displayedHistory.isEmpty }
                try await RenderedUI.wait { RenderedUI.contains(L("history.filter.reset"), in: host) }
                try RenderedUI.button(L("history.filter.reset"), in: host).press()
                try await RenderedUI.wait { model.displayedHistory.count == 1 }
                model.searchQuery = "no match"
                try await RenderedUI.wait { model.displayedHistory.isEmpty }
                model.searchQuery = "beta"
                try await RenderedUI.wait { model.displayedHistory.count == 1 }
                #expect(model.displayedHistory.first?.id == successful.id)
                model.clearHistory()
                try await RenderedUI.wait { model.displayedHistory.isEmpty && store.list().isEmpty }
            }
        }
    }

    @Test func `history pagination composes with filters and home ignores the history filter`() async throws {
        try await withModel(section: .history) { model, store in
            for index in 0 ..< 225 {
                store.save(record: HistoryRecord(date: Date().addingTimeInterval(Double(-index)),
                                                 transcriptText: "record \(index)", errorMessage: "failed"))
            }
            model.historyFilter = .failures
            try await RenderedUI.wait { model.displayedHistory.count == 100 }
            model.loadMoreHistoryIfNeeded()
            model.loadMoreHistoryIfNeeded()
            try await RenderedUI.wait { model.displayedHistory.count == 200 }
            try model.deleteHistoryRecord(id: #require(model.displayedHistory.first?.id))
            model.loadMoreHistoryIfNeeded()
            try await RenderedUI.wait { !model.canLoadMoreHistory && !model.isLoadingMoreHistory }
            #expect(model.displayedHistory.count == 224)
            #expect(Set(model.displayedHistory.map(\.id)).count == 224)
            model.historyFilter = .audio
            try await RenderedUI.wait { model.displayedHistory.isEmpty }
            model.navigate(to: .home)
            try await RenderedUI.wait { model.displayedHistory.count == 100 }
            model.navigate(to: .history)
            try await RenderedUI.wait { model.displayedHistory.isEmpty }
        }
    }

    @Test func `vocabulary transfer round trip retains sources and editing preserves identity`() async throws {
        try await withModel(section: .vocabulary) { model, _ in
            model.addVocabularyTerm("Alpha", source: .automatic)
            model.addVocabularyTerm("Beta", source: .codex)
            let data = try VocabularyStore.exportData()
            let items = try JSONDecoder().decode([VocabularyTransferItem].self, from: data)
            #expect(Set(items.map(\.source)) == [.automatic, .codex])
            try model.removeVocabularyEntry(id: #require(model.vocabularyEntries.first { $0.term == "Alpha" }?.id))
            let imported = try VocabularyStore.importItems(items)
            #expect(imported.addedCount == 1)
            try await RenderedUI.wait { model.vocabularyEntries.count == 2 }
            let beta = try #require(model.vocabularyEntries.first { $0.term == "Beta" })
            model.updateVocabularyEntry(id: beta.id, term: "Alpha")
            #expect(model.vocabularyEntries.count == 2)
            #expect(model.vocabularyEntries.contains { $0.id == beta.id && $0.term == "Beta" })
            model.updateVocabularyEntry(id: beta.id, term: "Gamma")
            let updated = try #require(model.vocabularyEntries.first { $0.id == beta.id })
            #expect(updated.term == "Gamma")
            #expect(updated.source == beta.source && updated.createdAt == beta.createdAt)
            #expect(updated.occurrenceCount == beta.occurrenceCount)
        }
    }
}

extension VocabularyHistorySettingsTests {
    @Test func `blank drafts disable saving while cancellation remains available`() async throws {
        try await RenderedUI.withFixture { _ in
            var cancelled = false
            var saved = false
            let sheet = VocabularyTermSheet(term: .constant(" \n "), isEditing: false,
                                            onCancel: { cancelled = true }, onSave: { saved = true })
            try await RenderedUI.withWindow(sheet, width: 480, height: 220) { _, host in
                let save = try RenderedUI.button(L("vocabulary.action.addWord"), in: host)
                try await RenderedUI.wait { save.value("isAccessibilityEnabled") as? Bool == false }
                try RenderedUI.button(L("common.cancel"), in: host).press()
                #expect(cancelled && !saved)
            }
        }
    }

    @Test func `detail actions preserve final text raw transcript retry and missing audio handling`() async throws {
        try await withModel(section: .history) { model, store in
            let record = HistoryRecord(date: Date(), audioFilePath: "/tmp/typeflux-fixture-missing.wav",
                                       transcriptText: "Raw transcript", personaPrompt: "Rewrite",
                                       postProcessedText: "Final result")
            store.save(record: record)
            model.navigate(to: .history)
            try await RenderedUI.wait { model.displayedHistory.count == 1 }
            let presentation = try #require(model.displayedHistory.first)
            try await RenderedUI
                .withWindow(VStack { HistorySettingsActions(record: presentation, viewModel: model) }) { _, host in
                    try RenderedUI.button(L("history.action.copyResult"), in: host).press()
                    #expect(NSPasteboard.general.string(forType: .string) == "Final result")
                    try RenderedUI.button(L("history.action.copyTranscript"), in: host).press()
                    #expect(NSPasteboard.general.string(forType: .string) == "Raw transcript")
                    try RenderedUI.button(L("common.retry"), in: host).press()
                    #expect(model.toastMessage == L("history.toast.retryStarted"))
                    try RenderedUI.button(L("history.action.downloadAudio"), in: host).press()
                    #expect(model.toastMessage == L("history.toast.audioUnavailable"))
                    try RenderedUI.button(L("history.action.deleteTranscript"), in: host).press()
                    #expect(store.record(id: record.id) == nil)
                }
            store.save(record: record)
            model.navigate(to: .history)
            try await RenderedUI.wait { model.displayedHistory.count == 1 }
            try await RenderedUI.withWindow(HistorySettingsDetailView(
                record: presentation,
                viewModel: model
            )) { _, host in
                try RenderedUI.button(L("history.action.playAudio"), in: host).press()
                #expect(model.toastMessage == L("history.toast.audioUnavailable"))
            }
        }
    }

    @Test func `timeline renders every stage and badge with solid accessible sections`() async throws {
        try await RenderedUI.withFixture { _ in
            let tones: [HistoryPipelineTimelineTone] = [.audio, .realtime, .transcription, .cloud, .local, .llm, .apply]
            let badges: [HistoryPipelineBadgePresentationItem.Tone] = [.neutral, .selected, .warning, .failure]
            let timeline = HistoryPipelineTimelinePresentation(
                totalDurationText: "1 s", timelineSpanDurationText: "1.2 s", slowestStageText: "Transcription",
                lanes: tones.enumerated().map { index, tone in
                    .init(id: "stage-\(index)", title: "Stage \(index)", durationMilliseconds: index * 100,
                          durationText: "\(index * 100) ms", offsetFraction: Double(index) / 10, widthFraction: 0.2,
                          tone: tone, isDetail: index > 3, isSlowest: index == 2)
                }, keyMetrics: [.init(id: "wait", title: "Key wait", value: "40 ms", style: .duration)],
                requestDetails: [.init(id: "request", title: "Request", endpoint: "https://fixture.invalid/v1",
                                       badges: ["HTTP", "200"])],
                summaryBadges: badges.enumerated().map { .init(id: "badge-\($0.offset)", title: "Badge \($0.offset)",
                                                               value: "Value \($0.offset)", tone: $0.element) }
            )
            try await RenderedUI.withWindow(
                TypefluxForm { HistoryPipelineTimelineView(title: "Pipeline", timeline: timeline) },
                height: 1600
            ) { _, host in
                #expect(RenderedUI.contains("Pipeline", in: host))
                for index in 0 ..< 7 {
                    #expect(RenderedUI.elements(in: host).contains { $0.label.contains("Stage \(index)") })
                }
                #expect(RenderedUI.elements(in: host).contains { $0.label.contains("https://fixture.invalid/v1") })
                #expect(RenderedUI.contains("Key wait", in: host))
            }
        }
    }

    @Test func `clearing history rejects a query that was already in flight`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.historyRetentionPolicy = .forever
            let store = HistorySettingsGateStore()
            defer { store.release.signal() }
            let model = StudioViewModel(settingsStore: settings, historyStore: store, initialSection: .history,
                                        modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                                      automaticallyLoadsCatalog: false))
            try await RenderedUI.wait { store.didEnter }
            model.clearHistory()
            store.release.signal()
            try await RenderedUI.wait { store.didReturn }
            try await Task.sleep(for: .milliseconds(30))
            #expect(model.displayedHistory.isEmpty)
            #expect(model.historyRecords.isEmpty)
            #expect(!model.canLoadMoreHistory && !model.isLoadingMoreHistory)
        }
    }

    private func withModel(section: StudioSection,
                           _ check: (StudioViewModel, SQLiteHistoryStore) async throws -> Void) async throws {
        try await RenderedUI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            settings.historyRetentionPolicy = .forever
            let store = SQLiteHistoryStore(baseDir: root)
            let model = StudioViewModel(settingsStore: settings, historyStore: store, initialSection: section,
                                        modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                                      automaticallyLoadsCatalog: false))
            try await check(model, store)
        }
    }

    private func deleteFromKeyboard(window: NSWindow, host: NSView) async throws {
        let currentTable = try vocabularyTable(in: host)
        try await RenderedUI.wait { currentTable.numberOfRows == 2 }
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(currentTable))
        #expect(window.firstResponder === currentTable)
        currentTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await RenderedUI.wait { currentTable.selectedRowIndexes.contains(0) }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil,
                                                  characters: String(UnicodeScalar(UInt32(127))!),
                                                  charactersIgnoringModifiers: String(
                                                      UnicodeScalar(UInt32(127))!
                                                  ),
                                                  isARepeat: false, keyCode: 51))
        let handler = try #require(descendants(host).compactMap {
            $0 as? TypefluxTableDeleteKey.KeyView
        }.first)
        #expect(handler.handle(event))
    }

    private func vocabularyTable(in host: NSView) throws -> NSTableView {
        let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
        #expect(table.tableColumns.count == 5)
        #expect(table.tableColumns.prefix(4).allSatisfy { $0.sortDescriptorPrototype != nil })
        return table
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
