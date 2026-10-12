import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class ModelPageTabTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ModelPageTabTests.\(UUID().uuidString)"))
    }

    private func makeViewModel(initialSection: StudioSection = .models) -> StudioViewModel {
        StudioViewModel(
            settingsStore: SettingsStore(defaults: defaults),
            historyStore: FileHistoryStore(
                baseDir: FileManager.default.temporaryDirectory.appendingPathComponent("ModelPageTabTests-\(UUID())")
            ),
            initialSection: initialSection,
            modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        )
    }

    // MARK: - ModelPageTab

    func testTabsAreOrderedScenesSpeechLanguage() {
        XCTAssertEqual(ModelPageTab.allCases, [.scenes, .speech, .language])
        XCTAssertEqual(ModelPageTab.speech.id, "speech")
    }

    func testTabsListTheirProviderDomain() {
        XCTAssertNil(ModelPageTab.scenes.domain)
        XCTAssertEqual(ModelPageTab.speech.domain, .stt)
        XCTAssertEqual(ModelPageTab.language.domain, .llm)
        XCTAssertEqual(ModelPageTab(domain: .stt), .speech)
        XCTAssertEqual(ModelPageTab(domain: .llm), .language)
    }

    func testTabTitlesAreDistinctAndNonEmpty() {
        let titles = ModelPageTab.allCases.map(\.title)
        XCTAssertFalse(titles.contains { $0.isEmpty })
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(ModelPageTab.speech.title, L("models.tab.speech"))
    }

    // MARK: - View model

    func testModelsPageOpensOnTheScenesTab() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.modelPageTab, .scenes)
        XCTAssertFalse(viewModel.isShowingModelProviderDetail)
    }

    func testSelectingAProviderTabSwitchesTheModelDomain() {
        let viewModel = makeViewModel()

        viewModel.selectModelPageTab(.language)
        XCTAssertEqual(viewModel.modelPageTab, .language)
        XCTAssertEqual(viewModel.modelDomain, .llm)

        viewModel.selectModelPageTab(.speech)
        XCTAssertEqual(viewModel.modelPageTab, .speech)
        XCTAssertEqual(viewModel.modelDomain, .stt)
    }

    func testSelectingTheScenesTabKeepsTheModelDomain() {
        let viewModel = makeViewModel()
        viewModel.selectModelPageTab(.language)

        viewModel.selectModelPageTab(.scenes)

        XCTAssertEqual(viewModel.modelPageTab, .scenes)
        XCTAssertEqual(viewModel.modelDomain, .llm)
    }

    func testSelectingATabClosesProviderDetailAndClearsSearch() {
        let viewModel = makeViewModel()
        viewModel.selectModelPageTab(.language)
        viewModel.selectedLanguageProviderID = "openAI"
        viewModel.isShowingSpeechProviderDetail = true
        viewModel.modelSearchQuery = "gpt"

        viewModel.selectModelPageTab(.language)

        XCTAssertNil(viewModel.selectedLanguageProviderID)
        XCTAssertFalse(viewModel.isShowingSpeechProviderDetail)
        XCTAssertEqual(viewModel.modelSearchQuery, "")
    }

    func testProviderDetailOnlyCountsOnItsOwnTab() {
        let viewModel = makeViewModel()
        viewModel.selectModelPageTab(.speech)
        viewModel.isShowingSpeechProviderDetail = true
        XCTAssertTrue(viewModel.isShowingModelProviderDetail)

        viewModel.selectModelPageTab(.language)
        XCTAssertFalse(viewModel.isShowingModelProviderDetail)
        viewModel.selectedLanguageProviderID = "openAI"
        XCTAssertTrue(viewModel.isShowingModelProviderDetail)

        viewModel.selectModelPageTab(.scenes)
        viewModel.selectedLanguageProviderID = "openAI"
        viewModel.isShowingSpeechProviderDetail = true
        XCTAssertFalse(viewModel.isShowingModelProviderDetail)
    }

    func testMissingProviderKeepsListActionsAvailable() {
        let viewModel = makeViewModel()
        viewModel.selectModelPageTab(.language)
        viewModel.selectedLanguageProviderID = "removed-provider"
        XCTAssertFalse(viewModel.isShowingModelProviderDetail)
    }

    func testReturningToModelsKeepsTheTabButResetsSearchAndSpeechDetail() {
        let viewModel = makeViewModel()
        viewModel.selectModelPageTab(.speech)
        viewModel.isShowingSpeechProviderDetail = true
        viewModel.modelSearchQuery = "whisper"

        viewModel.navigate(to: .agent)
        viewModel.navigateFromSidebar(to: .models)

        XCTAssertEqual(viewModel.currentSection, .models)
        XCTAssertEqual(viewModel.modelPageTab, .speech)
        XCTAssertFalse(viewModel.isShowingSpeechProviderDetail)
        XCTAssertEqual(viewModel.modelSearchQuery, "")
    }

    func testOtherSectionsLeaveTheModelSearchAlone() {
        let viewModel = makeViewModel()
        viewModel.selectModelPageTab(.language)
        viewModel.modelSearchQuery = "claude"

        viewModel.navigate(to: .settings)

        XCTAssertEqual(viewModel.modelSearchQuery, "claude")
    }

    // MARK: - Views

    func testTabBarRendersEveryModelTab() {
        let host = NSHostingView(rootView: ModelPageTabBar(selection: .speech, onSelect: { _ in }))
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testModelsPageRendersEveryTabAndDetail() {
        let viewModel = makeViewModel()
        let states: [(ModelPageTab, (StudioViewModel) -> Void)] = [
            (.scenes, { _ in }),
            (.speech, { _ in }),
            (.speech, { $0.isShowingSpeechProviderDetail = true }),
            (.language, { _ in }),
            (.language, { $0.modelSearchQuery = "no-such-provider" }),
            (.language, { $0.selectedLanguageProviderID = "openAI" }),
            (.language, { $0.selectedLanguageProviderID = "missing-provider" })
        ]
        for (tab, configure) in states {
            viewModel.selectModelPageTab(tab)
            configure(viewModel)
            let page = ModelSettingsPage(viewModel: viewModel, library: viewModel.modelLibrary) {
                Text("speech detail")
            }
            let host = NSHostingView(rootView: page.frame(width: 860, height: 720))
            host.frame = NSRect(x: 0, y: 0, width: 860, height: 720)
            host.layoutSubtreeIfNeeded()

            XCTAssertEqual(host.fittingSize.width, 860, "\(tab)")
        }
    }

    func testStudioViewRendersTheModelsHeaderOnEveryTab() {
        let viewModel = makeViewModel()
        for tab in ModelPageTab.allCases {
            viewModel.selectModelPageTab(tab)
            let host = NSHostingView(rootView: StudioView(viewModel: viewModel))
            host.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
            host.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(host.fittingSize.height, 0, "\(tab)")
        }
    }
}
