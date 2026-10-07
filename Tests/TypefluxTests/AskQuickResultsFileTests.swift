import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Ask quick results with files")
struct AskQuickResultsFileTests {
    private let apps = AskTestAppIndex(AskTestAppIndex.sample.entries + [
        AskAppEntry(name: "网络", url: URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/Network.appex"),
                    bundleID: "com.apple.Network-Settings.extension", names: ["Network"], kind: .settingsPane)
    ])
    private let files = AskTestFileIndex.sample

    private func resolve(_ text: String, mode: AskLauncherSearchSettings.Mode = .mixed,
                         files: AskTestFileIndex? = nil, apps: Bool = true,
                         previous: AskQuickResults? = nil) -> AskQuickResults? {
        var settings = AskLauncherSearchSettings()
        settings.mode = mode
        return AskQuickResults.resolve(text: text, previous: previous, chinese: true, calculator: true,
                                       sources: .init(apps: apps ? self.apps : nil, files: files ?? self.files,
                                                      settings: settings))
    }

    @Test func aClearFileLeadsAndTakesReturn() throws {
        let results = try #require(resolve("readme"))
        // Two READMEs: the newer one is ahead, but not by enough to take Return.
        #expect(results.best == nil)
        #expect(results.rows.first == .askAI)
        let contract = try #require(resolve("hetong"))
        #expect(contract.best == .file(contract.files.firstIndex { $0.name == "合同" }!), "the folder's whole pinyin")
        #expect(contract.highlightedRow == contract.best)
        #expect(contract.rows.last == .askAI)
        #expect(contract.groups.contains(.files) && contract.groups.contains(.folders))
    }

    @Test func applicationsKeepTheirRuleAndWinTies() throws {
        let wechat = try #require(resolve("wx"))
        #expect(wechat.best == .app(0))
        #expect(wechat.rows == [.app(0), .askAI])
        let pane = try #require(resolve("网络"))
        #expect(pane.best == .pane(0))
        #expect(pane.app(at: .pane(0))?.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.Network-Settings.extension")
        #expect(pane.match(at: .pane(0))?.entry.kind == .settingsPane)
        #expect(pane.match(at: .askAI) == nil)
    }

    @Test func questionsAndLongTextNeverLead() throws {
        let question = try #require(resolve("readme?"))
        #expect(question.best == nil)
        #expect(resolve("how do I write a readme for my project today please") == nil, "a sentence is for the AI")
        #expect(AskQuickResults.bestRow("a b c d", apps: [], panes: [], files: []) == nil)
        #expect(AskQuickResults.bestRow("ab", apps: [], panes: [], files: []) == nil)
    }

    @Test func modesOrderTheGroups() throws {
        let mixed = try #require(resolve("notes"))
        #expect(mixed.groups.first == .apps, "Notes the app is the best match")
        let filesFirst = try #require(resolve("t", mode: .filesFirst))
        let appsFirst = try #require(resolve("t", mode: .appsFirst))
        if filesFirst.groups.contains(.files), filesFirst.groups.contains(.apps) {
            #expect(filesFirst.groups.firstIndex(of: .files)! < filesFirst.groups.firstIndex(of: .apps)!)
            #expect(appsFirst.groups.firstIndex(of: .apps)! < appsFirst.groups.firstIndex(of: .files)!)
        }
    }

    @Test func manyFilesOfferShowAll() throws {
        var entries: [(path: String, kind: AskFileRecord.Kind, days: Double)] = []
        for number in 0 ..< 10 { entries.append(("/Users/test/r/report-\(number).txt", .file, Double(number))) }
        let many = AskTestFileIndex(entries)
        let results = try #require(resolve("report", files: many, apps: false))
        #expect(results.files.filter { !$0.isFolder }.count == AskQuickResults.fileLimit)
        #expect(results.moreFiles)
        #expect(results.rows.contains(.showAllFiles))
        #expect(results.value(of: .showAllFiles) == nil)
        #expect(AskQuickResultsView.hint(for: {
            var copy = results
            copy.highlight(copy.rows.firstIndex(of: .showAllFiles)!)
            return copy
        }()) == L("ask.quick.hint.showAll"))
    }

    @Test func aChosenFileStaysChosenWhileTyping() throws {
        var results = try #require(resolve("invoice"))
        let older = try #require(results.rows.firstIndex { results.file(at: $0)?.name == "invoice-2026-08.pdf" })
        results.highlight(older)
        let next = try #require(resolve("invoice-", previous: results))
        #expect(next.file(at: next.highlightedRow)?.name == "invoice-2026-08.pdf")
        #expect(next.chosen)
        #expect(AskQuickResultsView.hint(for: next) == L("ask.quick.hint.file"))
        #expect(next.file(at: .askAI) == nil)
        #expect(next.app(at: .file(0)) == nil)
    }

    @Test func theIndexBeingBuiltIsSaid() throws {
        let building = AskTestFileIndex([("/Users/test/a/readme.md", .file, 1)])
        building.status = AskFileIndexStatus(phase: .building(found: 1234, estimate: 2000))
        let results = try #require(resolve("readme", files: building, apps: false))
        #expect(results.notice == .indexing(found: 1234, progress: 0.617))
        let withNotice = AskQuickResultsView.height(for: results)
        var without = results
        without.notice = nil
        #expect(withNotice - AskQuickResultsView.height(for: without)
            == AskQuickResultsView.noticeHeight + AskQuickResultsView.rowSpacing)
    }

    @Test func sectionsNameEachKind() throws {
        let contract = try #require(resolve("hetong"))
        let rows = contract.rows
        #expect(AskQuickResultsView.sectionStart(at: 0, in: rows, results: contract) == .best)
        #expect(rows.indices.compactMap { AskQuickResultsView.sectionStart(at: $0, in: rows, results: contract) }.contains(.files))
        #expect(AskQuickResultsView.section(of: .pane(0)) == .panes)
        #expect(AskQuickResultsView.section(of: .showAllFiles) == .files)
        for section in [AskQuickResultsView.Section.best, .panes, .files, .folders] {
            #expect(!section.title.hasPrefix("ask.quick"))
        }
        #expect(AskQuickResultsView.rowHeight(.showAllFiles) == AskQuickResultsView.moreHeight)
        #expect(AskQuickResultsView.rowHeight(.file(0)) == AskQuickResultsView.fileHeight)
    }

    @Test func tallListsStopGrowing() throws {
        var results = try #require(resolve("t"))
        results.files = Array(repeating: AskFileHit(path: "/x/a.txt", name: "a.txt", kind: .file, modified: Date(), score: 1),
                              count: 40)
        results.groups = [.files]
        #expect(AskQuickResultsView.height(for: results) == AskQuickResultsView.maximumHeight)
        #expect(AskQuickResultsView.contentHeight(for: results) > AskQuickResultsView.maximumHeight)
    }

    @Test func relativeDatesReadNaturally() {
        let now = Date()
        #expect(AskQuickResultsView.relative(now, now: now) == L("ask.quick.file.today"))
        #expect(AskQuickResultsView.relative(now.addingTimeInterval(-86400), now: now) == L("ask.quick.file.yesterday"))
        #expect(!AskQuickResultsView.relative(now.addingTimeInterval(-86400 * 10), now: now).isEmpty)
    }

    @Test func fileTypesSortByExtension() {
        #expect(AskFileType.pdf.matches(kind: .file, extension: "pdf"))
        #expect(!AskFileType.pdf.matches(kind: .folder, extension: "pdf"))
        #expect(AskFileType.folder.matches(kind: .folder, extension: ""))
        #expect(AskFileType.all.matches(kind: .file, extension: "zzz"))
        #expect(AskFileType.code.matches(kind: .file, extension: "swift"))
        #expect(AskFileType.all.next(1) == .folder)
        #expect(AskFileType.all.next(-1) == .code)
        #expect(AskFileType.hasThumbnail("png") && AskFileType.hasThumbnail("pdf"))
        #expect(!AskFileType.hasThumbnail("svg") && !AskFileType.hasThumbnail("txt"))
        #expect(AskFileType.allCases.allSatisfy { !$0.title.hasPrefix("ask.search") })
    }
}

@Suite("Ask quick action panel")
struct AskQuickActionPanelTests {
    private let file = AskFileHit(path: "/tmp/a.pdf", name: "a.pdf", kind: .file, modified: Date(), score: 1)
    private let folder = AskFileHit(path: "/tmp/f", name: "f", kind: .folder, modified: Date(), score: 1)

    @Test func eachKindHasItsActions() throws {
        let files = try #require(AskQuickActionPanel.make(for: .file(file)))
        #expect(files.actions.first == .open)
        #expect(files.actions.contains(.quickLook) && files.actions.contains(.trash) && files.actions.contains(.askAI))
        let folders = try #require(AskQuickActionPanel.make(for: .file(folder)))
        #expect(folders.actions.contains(.openInTerminal) && folders.actions.contains(.searchInFolder))
        #expect(!folders.actions.contains(.quickLook))
        let app = AskTestAppIndex.app("Notes", id: "com.apple.Notes")
        #expect(AskQuickActionPanel.make(for: .app(app), running: { _ in true })?.actions.last == .quit)
        #expect(AskQuickActionPanel.make(for: .app(app), running: { _ in false })?.actions.contains(.quit) == false)
        let pane = AskAppEntry(name: "网络", url: URL(fileURLWithPath: "/x.appex"), bundleID: "x", names: [], kind: .settingsPane)
        #expect(AskQuickActionPanel.make(for: .app(pane)) == nil, "a settings pane only opens")
        #expect(files.title == "a.pdf")
        #expect(AskQuickActionPanel(target: .app(app), actions: []).title == "Notes")
    }

    @Test func movingWrapsAndCancelsConfirmation() throws {
        var panel = try #require(AskQuickActionPanel.make(for: .file(file)))
        panel.move(-1)
        #expect(panel.highlightedAction == .trash)
        panel.confirming = true
        panel.move(1)
        #expect(panel.highlightedAction == .open)
        #expect(!panel.confirming)
        var empty = AskQuickActionPanel(target: .file(file), actions: [])
        empty.move(1)
        #expect(empty.highlightedAction == nil)
    }

    @Test func actionsDescribeThemselves() {
        let all: [AskQuickAction] = [.open, .openWith, .openIn(URL(fileURLWithPath: "/System/Applications/Preview.app")),
                                     .reveal, .quickLook, .copyPath, .copyFile, .copyName, .askAI, .openInTerminal,
                                     .searchInFolder, .quit, .trash]
        for action in all {
            #expect(!action.title.isEmpty && !action.title.hasPrefix("ask.quick"))
            #expect(!action.symbol.isEmpty)
        }
        #expect(AskQuickAction.reveal.shortcut == "⌘R")
        #expect(AskQuickAction.trash.shortcut == nil)
        #expect(AskQuickAction.trash.destructive && AskQuickAction.quit.destructive && !AskQuickAction.open.destructive)
        #expect(AskQuickAction.openIn(URL(fileURLWithPath: "/System/Applications/Preview.app")).title.contains("Preview")
            || AskQuickAction.openIn(URL(fileURLWithPath: "/System/Applications/Preview.app")).title.contains("预览"))
    }
}

@Suite("Ask file search plugin")
struct AskFileSearchPluginTests {
    private func plugin(_ index: AskTestFileIndex?, limit: Int = 30) -> AskFileSearchPlugin {
        var settings = AskLauncherSearchSettings()
        settings.limit = limit
        let current = settings
        return AskFileSearchPlugin(index: { index }, settings: { current })
    }

    private func request(_ text: String, options: [String: String] = [:]) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: .argument, keyword: AskFileSearchPlugin.keywords[0], options: options,
                         interfaceLanguage: .english)
    }

    private func run(_ plugin: AskFileSearchPlugin, _ request: AskPluginRequest) async throws -> AskPluginOutput {
        let plan = await plugin.plan(request)
        #expect(plan.mode == .live)
        return try await plugin.run(request, plan: plan, progress: { _ in })
    }

    @Test func listsMatchesWithTheirActions() async throws {
        let output = try await run(plugin(AskTestFileIndex.sample), request("invoice"))
        #expect(output.items.map(\.title) == ["invoice-2026-09.pdf", "invoice-2026-08.pdf"])
        let first = try #require(output.items.first)
        #expect(first.subtitle.hasPrefix("/Users/test/Documents/发票 · "))
        #expect(first.icon == .fileIcon(URL(fileURLWithPath: "/Users/test/Documents/发票/invoice-2026-09.pdf")))
        #expect(output.action(for: .enter)?.kind == .open(URL(fileURLWithPath: "/Users/test/Documents/发票/invoice-2026-09.pdf")))
        #expect(output.action(for: .commandR) != nil)
        #expect(output.action(for: .shiftCommandC)?.kind == .copy("/Users/test/Documents/发票/invoice-2026-09.pdf"))
        #expect(output.note == nil)
        #expect(!output.source.isEmpty)
    }

    @Test func emptyTextListsRecentFilesAndTypesNarrow() async throws {
        let plugin = plugin(AskTestFileIndex.sample, limit: 10)
        let recent = try await run(plugin, request(""))
        #expect(recent.items.first?.title == "内容搜索方案.md")
        let pdfs = try await run(plugin, request("", options: [AskFileSearchPlugin.typeOption: "pdf"]))
        #expect(pdfs.items.count == 3)
        let folders = try await run(plugin, request("合同", options: [AskFileSearchPlugin.typeOption: "folder"]))
        #expect(folders.items.map(\.title) == ["合同"])
        #expect(folders.items[0].actions.contains { if case .runWith = $0.kind { true } else { false } },
                "a folder offers searching inside it")
        let next = plugin.nextOptions(after: await plugin.plan(request("")), request: request(""), step: 1)
        #expect(next == [AskFileSearchPlugin.typeOption: "folder"])
        #expect(plugin.chipDetail(for: AskKeyword(keyword: "fp", pluginID: AskFileSearchPlugin.id,
                                                  options: [AskFileSearchPlugin.typeOption: "pdf"]), language: .english) == "PDF")
        #expect(plugin.chipDetail(for: AskFileSearchPlugin.keywords[0], language: .english) == nil)
        #expect(plugin.runsWithoutInput && plugin.optionName != nil && !plugin.placeholder(selectionLines: nil).isEmpty)
    }

    @Test func saysWhenNothingIsFoundOrSearchIsOff() async throws {
        let none = try await run(plugin(AskTestFileIndex.sample), request("zzzz"))
        #expect(none.items.count == 1 && !none.items[0].valid)
        let off = try await run(plugin(nil), request("readme"))
        #expect(off.items.count == 1 && !off.items[0].valid)
    }

    @Test func offersToUnlockGuardedFoldersAndShowsProgress() async throws {
        let index = AskTestFileIndex.sample
        index.status = AskFileIndexStatus(phase: .building(found: 10, estimate: nil), blocked: ["/Users/test/Documents"])
        let output = try await run(plugin(index), request("invoice"))
        let unlock = try #require(output.items.last)
        #expect(unlock.valid)
        #expect(unlock.actions.first?.kind == .open(AskFullDiskAccess.settingsURL))
        #expect(output.note?.contains("10") == true)
        index.status = AskFileIndexStatus(phase: .ready)
    }
}
