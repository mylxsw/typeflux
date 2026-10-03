import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask local mode surfaces", .serialized)
@MainActor
struct AskLocalModeUITests {
    private let text = RegisteredModel(id: "qwen3:8b", name: "qwen3:8b", reference: "custom:text", vision: false)
    private let vision = RegisteredModel(id: "llama3.2-vision:11b", name: "llama3.2-vision:11b",
                                         reference: "custom:vision", vision: true)

    /// A signed-out Mac whose Ollama has the given models, the first being the default.
    private func localFixture(_ models: [RegisteredModel]) throws -> AskTestFixture {
        let defaults = try #require(UserDefaults(suiteName: "ask-local-mode-" + UUID().uuidString))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        // Start from the user's own models only, without the migrated Ollama default.
        var registry = library.registry
        if let index = registry.providers.firstIndex(where: { $0.isOllama }) { registry.providers[index].models = [] }
        try library.commit(registry)
        try library.addModels(models, providerID: "ollama")
        library.ollamaAvailable = true
        library.defaultReference = models.first?.reference ?? "cloud:default"
        return try AskTestFixture(localOnly: true, modelLibrary: library)
    }

    private func fits<V: View>(_ view: V, width: CGFloat? = nil) -> CGSize {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    // MARK: - Vision switch

    @Test func screenshotSuggestionMovesALocalDraftToAVisionModel() throws {
        let f = try localFixture([text, vision])
        #expect(f.model.screenshotSuggestion(launcher: false) == .switches(model: vision.name))
        f.model.draft.screenshot = "data:image/png;base64,YQ=="
        f.model.attachScreenshotForSuggestion(launcher: false)
        #expect(f.model.draft.modelRef == vision.reference)
        #expect(f.model.draft.includeScreenshot)
        #expect(f.model.screenshotSuggestion(launcher: false) == .ready)
        let change = try #require(f.model.visibleVisionSwitch)
        #expect(change == AskVisionSwitch(draftKey: "new", from: text.reference, to: vision.reference))
    }

    @Test func switchingBackSticksForThatDraft() throws {
        let f = try localFixture([text, vision])
        #expect(f.model.switchToVisionModelIfNeeded(launcher: false, needsVision: true))
        f.model.revertVisionSwitch()
        #expect(f.model.draft.modelRef == text.reference)
        #expect(f.model.visionSwitch == nil)
        #expect(f.model.visionSwitchDeclined.contains("new"))
        #expect(!f.model.switchToVisionModelIfNeeded(launcher: false, needsVision: true))
        // Nothing to revert once the banner is gone.
        f.model.revertVisionSwitch()
        #expect(f.model.draft.modelRef == text.reference)
    }

    @Test func noSwitchWithoutANeedOrACandidate() throws {
        let f = try localFixture([text, vision])
        #expect(!f.model.switchToVisionModelIfNeeded(launcher: false))
        let textOnly = try localFixture([text])
        #expect(textOnly.model.visionCandidate(launcher: false) == nil)
        #expect(!textOnly.model.switchToVisionModelIfNeeded(launcher: false, needsVision: true))
        #expect(textOnly.model.screenshotSuggestion(launcher: false) == .needsVisionModel)
        textOnly.model.attachScreenshotForSuggestion(launcher: false)
        #expect(!textOnly.model.draft.includeScreenshot)
        let visionOnly = try localFixture([vision])
        #expect(visionOnly.model.screenshotSuggestion(launcher: false) == .ready)
    }

    @Test func launcherSwitchesWithoutABanner() throws {
        let f = try localFixture([text, vision])
        f.model.launcherDraft.screenshot = "data:image/png;base64,YQ=="
        f.model.attachScreenshotForSuggestion(launcher: true)
        #expect(f.model.launcherDraft.modelRef == vision.reference)
        #expect(f.model.launcherDraft.includeScreenshot)
        #expect(f.model.visionSwitch == nil)
        #expect(f.model.visionDraftKey(launcher: true) == "launcher")
    }

    @Test func openingAConversationWithImagesSwitchesIt() async throws {
        let f = try localFixture([text, vision])
        await f.api.seed(AskConversation(id: "img", title: "Screen", revision: 1, updatedAt: Date(), messages: [
            AskMessage(id: "q", role: "user", text: "What is this?", image: "data:image/png;base64,YQ==", createdAt: Date())
        ], modelRef: text.reference))
        await f.model.select("img")
        #expect(f.model.modelReference(launcher: false) == vision.reference)
        #expect(f.model.visibleVisionSwitch?.draftKey == "img")
        #expect(f.model.visibleVisionSwitch?.from == text.reference)
        f.model.newConversation()
        #expect(f.model.visionSwitch == nil)
        f.model.resetSession()
    }

    @Test func cloudKeepsItsOwnScreenshotRules() throws {
        let f = try AskTestFixture()
        #expect(f.model.visionCandidate(launcher: false) == nil)
        #expect(f.model.screenshotSuggestion(launcher: false) == .ready)
        f.model.draft.modelRef = "custom:missing"
        #expect(f.model.screenshotSuggestion(launcher: false) == .unavailable(reason: L("ask.models.unavailable")))
    }

    @Test func suggestionStatesDescribeThemselves() {
        #expect(AskScreenshotSuggestion.ready.enabled)
        #expect(AskScreenshotSuggestion.switches(model: "m").enabled)
        #expect(!AskScreenshotSuggestion.needsVisionModel.enabled)
        #expect(!AskScreenshotSuggestion.unavailable(reason: "r").enabled)
        #expect(AskScreenshotSuggestion.ready.caption(default: "d") == "d")
        #expect(AskScreenshotSuggestion.switches(model: "m").caption(default: "d") == String(format: L("ask.vision.willUse"), "m"))
        #expect(AskScreenshotSuggestion.needsVisionModel.caption(default: "d") == L("ask.vision.none"))
        #expect(AskScreenshotSuggestion.unavailable(reason: "r").caption(default: "d") == "r")
    }

    // MARK: - Launcher suggestions

    @Test func launcherSkipsSuggestionsThatCannotRun() {
        let blocked = AskLauncherSuggestions.disabled(screenshot: .needsVisionModel)
        #expect(blocked == [0])
        #expect(AskLauncherSuggestions.disabled(screenshot: .switches(model: "m")).isEmpty)
        #expect(AskSuggestion.step(1, by: 1, skipping: blocked) == 2)
        #expect(AskSuggestion.step(2, by: 1, skipping: blocked) == 1)
        #expect(AskSuggestion.step(1, by: -1, skipping: blocked) == 2)
        #expect(AskSuggestion.step(0, by: 1, skipping: [0, 1, 2]) == 0)
        #expect(AskSuggestion.step(0, by: 1, count: 0) == 0)
        #expect(AskSuggestion.available(0, skipping: blocked) == 1)
        #expect(AskSuggestion.available(2, skipping: blocked) == 2)
    }

    @Test func launcherSuggestionsRenderEveryScreenshotState() {
        for state in [AskScreenshotSuggestion.ready, .switches(model: "llama3.2-vision"), .needsVisionModel,
                      .unavailable(reason: "No")] {
            let size = fits(AskLauncherSuggestions(highlighted: .constant(0), screenshot: state, onPick: { _ in }),
                            width: 640)
            #expect(abs(size.height - AskLauncherSuggestions.height) < 1)
        }
    }

    // MARK: - Status card, sidebar and promo

    @Test func statusNamesTheSourceAndOffersCloudOnlyWhenSignedOut() throws {
        let f = try localFixture([text])
        let signedOut = AskLocalModeStatus.make(model: f.model, signedIn: false)
        #expect(signedOut.source == "Ollama")
        #expect(signedOut.offersSignIn)
        #expect(!AskLocalModeStatus.make(model: f.model, signedIn: true).offersSignIn)
        f.model.draft.modelRef = "custom:missing"
        #expect(AskLocalModeStatus.make(model: f.model, signedIn: false).source == L("ask.local.sourceNone"))
        #expect(AskLocalModeStatus.sourceName(.init(id: "endpoint:x", name: "Work API")) == "Work API")
    }

    @Test func promoReturnsAfterItsQuietPeriod() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(AskCloudPromo.isVisible(dismissedAt: 0, now: now))
        #expect(!AskCloudPromo.isVisible(dismissedAt: now.timeIntervalSince1970 - 60, now: now))
        #expect(AskCloudPromo.isVisible(dismissedAt: now.timeIntervalSince1970 - AskCloudPromo.quietPeriod, now: now))
    }

    @Test func localSurfacesRender() throws {
        let f = try localFixture([text, vision])
        for status in [AskLocalModeStatus(source: "Ollama", searchConfigured: false, offersSignIn: true),
                       AskLocalModeStatus(source: "Ollama", searchConfigured: true, offersSignIn: false)] {
            #expect(fits(AskLocalModeCard(status: status, onOpenSearchSettings: {}, onSignIn: {})).height > 100)
        }
        #expect(fits(AskCloudPromoCard(onSignIn: {}, onDismiss: {}), width: 236).height > 60)
        #expect(fits(AskLocalModeIdentity(model: f.model), width: 200).height == 40)
        #expect(fits(AskLocalModeButton(model: f.model)).height == 22)
        #expect(fits(AskLocalModeButton(model: try AskTestFixture().model)) == .zero)
    }

    @Test func workspaceRendersTheSignedOutFooterAndSwitchBanner() throws {
        let f = try localFixture([text, vision])
        let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil })
        f.model.switchToVisionModelIfNeeded(launcher: false, needsVision: true)
        #expect(fits(AskConversationView(model: f.model, auth: auth), width: 1100).height >= 530)
    }

    // MARK: - Model menu

    @Test func menuGroupsBySourceAndLabelsLocalModels() {
        let ollama = RegisteredProvider(id: "ollama", name: "Ollama")
        let custom = RegisteredProvider(id: "endpoint:x", name: "Work API")
        let cloud = RegisteredProvider(id: LLMRemoteProvider.typefluxCloud.rawValue, name: "Typeflux Cloud",
                                       remote: .typefluxCloud)
        #expect(AskModelChoices.groupTitle(ollama) == L("ask.models.localGroup"))
        #expect(AskModelChoices.groupTitle(custom) == "Work API")
        #expect(AskModelChoices.sourceTag(ollama) == L("ask.location.local"))
        #expect(AskModelChoices.sourceTag(custom) == L("ask.models.ownAPI"))
        #expect(AskModelChoices.sourceTag(cloud) == nil)
    }

    @Test func composerShowsOnlyTheModelName() throws {
        // Same name, different vision: the footer control must not grow a capability icon.
        let seeing = RegisteredModel(id: "same-a", name: "same", reference: "custom:seeing", vision: true)
        let blind = RegisteredModel(id: "same-b", name: "same", reference: "custom:blind", vision: false)
        let f = try localFixture([seeing, blind])
        let library = f.model.modelLibrary
        let seeingSize = fits(AskModelMenu(library: library, reference: .constant(seeing.reference), compact: true,
                                           cloudAvailable: false))
        let blindSize = fits(AskModelMenu(library: library, reference: .constant(blind.reference), compact: true,
                                          cloudAvailable: false))
        #expect(seeingSize.height > 20)
        #expect(seeingSize.width == blindSize.width)
    }

    @Test func composerMenuShowsImageNoteAndLockedCloud() throws {
        let f = try localFixture([text, vision])
        let library = f.model.modelLibrary
        let plain = fits(AskModelChoices(library: library, reference: .constant(text.reference), loggedIn: false,
                                         composerStyle: true))
        let images = fits(AskModelChoices(library: library, reference: .constant(vision.reference), hasImage: true,
                                          loggedIn: false, composerStyle: true))
        let locked = fits(AskModelChoices(library: library, reference: .constant(text.reference), loggedIn: false,
                                          composerStyle: true, offersCloudSignIn: true))
        #expect(images.height > plain.height)
        #expect(locked.height > plain.height)
    }
}
