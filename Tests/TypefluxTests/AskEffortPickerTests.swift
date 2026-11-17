import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Five reasoning levels, offered per model; the composer's chip shows the model and
/// the level, and its card holds the slider and the model list.
@Suite("Ask effort picker", .serialized, .exclusiveUIState)
@MainActor
struct AskEffortPickerTests {
    private let five = RegisteredModel(id: "deep", name: "Deep", reference: "cloud:deep", reasoning: true,
                                       reasoningEfforts: ["max", "low", "xhigh", "high", "medium"])
    private let three = RegisteredModel(id: "three", name: "Three", reference: "cloud:three", reasoning: true)
    private let plain = RegisteredModel(id: "plain", name: "Plain", reference: "cloud:plain", reasoning: false)

    @Test func levelsFollowTheCatalogAndDefaultToThree() {
        #expect(AskReasoningEffort.levels(for: five) == AskReasoningEffort.levels)
        #expect(AskReasoningEffort.levels(for: three) == AskReasoningEffort.defaultLevels)
        #expect(AskReasoningEffort.levels(for: plain).isEmpty)
        #expect(AskReasoningEffort.levels(for: nil).isEmpty)
        let odd = RegisteredModel(id: "odd", name: "Odd", reference: "cloud:odd", reasoning: true,
                                  reasoningEfforts: ["turbo", "max"])
        #expect(AskReasoningEffort.levels(for: odd) == [.max])
        let unknown = RegisteredModel(id: "x", name: "X", reference: "cloud:x", reasoning: true,
                                      reasoningEfforts: ["turbo"])
        #expect(AskReasoningEffort.levels(for: unknown) == AskReasoningEffort.defaultLevels)
        // The user's own models offer the default levels unless known not to reason.
        #expect(AskReasoningEffort.levels(for: .init(id: "own", name: "Own")) == AskReasoningEffort.defaultLevels)
        #expect(AskReasoningEffort.levels(for: .init(id: "own", name: "Own", reasoning: false)).isEmpty)
    }

    @Test func nearestKeepsOfferedLevelsAndMovesOthersToTheClosest() {
        let three = AskReasoningEffort.defaultLevels
        #expect(AskReasoningEffort.max.nearest(in: three) == .high)
        #expect(AskReasoningEffort.xhigh.nearest(in: three) == .high)
        #expect(AskReasoningEffort.medium.nearest(in: three) == .medium)
        #expect(AskReasoningEffort.providerDefault.nearest(in: three) == .providerDefault)
        #expect(AskReasoningEffort.high.nearest(in: []) == .providerDefault)
        // A tie goes to the lighter level.
        #expect(AskReasoningEffort.medium.nearest(in: [.low, .high]) == .low)
        #expect(AskReasoningEffort.max.nearest(in: [.medium, .xhigh]) == .xhigh)
    }

    @Test func requestsSendTheNearestOfferedLevel() {
        #expect(AskReasoningEffort.max.requestValue(for: five) == "max")
        #expect(AskReasoningEffort.max.requestValue(for: three) == "high")
        #expect(AskReasoningEffort.max.requestValue(for: plain) == nil)
        #expect(AskReasoningEffort.providerDefault.requestValue(for: five) == nil)
        #expect(AskReasoningEffort.isAvailable(for: five))
        #expect(!AskReasoningEffort.isAvailable(for: plain))
    }

    @Test func catalogLevelsDecodeAndSurviveTheRegistry() throws {
        let json = #"{"id":"deep","name":"Deep","capabilities":{"reasoning":true},"#
            + #""reasoning_efforts":["low","high","max"]}"#
        let model = try AskCoding.decoder().decode(AskCloudModel.self, from: Data(json.utf8))
        #expect(model.reasoningEfforts == ["low", "high", "max"])
        let restored = try JSONDecoder().decode(RegisteredModel.self, from: JSONEncoder().encode(model.registered))
        #expect(AskReasoningEffort.levels(for: restored) == [.low, .high, .max])
        let older = try AskCoding.decoder().decode(AskCloudModel.self, from: Data(#"{"id":"o","name":"O"}"#.utf8))
        #expect(older.reasoningEfforts == nil)
    }

    @Test func everyLevelHasItsOwnLabelAndCaption() {
        let labels = AskReasoningEffort.allCases.map(\.label)
        let captions = AskReasoningEffort.allCases.map(\.caption)
        #expect(labels.allSatisfy { !$0.isEmpty && !$0.hasPrefix("ask.") })
        #expect(Set(labels).count == labels.count)
        #expect(Set(captions).count == captions.count)
    }

    private func fixture() throws -> AskTestFixture {
        let defaults = try #require(UserDefaults(suiteName: "ask-effort-" + UUID().uuidString))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let models = [five, three, plain].map { model in
            var copy = model
            copy.scenarios = ["ask"]
            return copy
        }
        try library.addModels(models, providerID: "typefluxCloud")
        return try AskTestFixture(modelLibrary: library)
    }

    @Test func switchingToAModelWithFewerLevelsMovesTheChoiceOnce() throws {
        let fixture = try fixture()
        defer { fixture.model.resetSession() }
        fixture.model.selectModel(five.reference, launcher: false)
        fixture.model.reasoningEffort = .max
        #expect(fixture.model.displayedReasoningEffort(launcher: false) == .max)
        fixture.model.selectModel(three.reference, launcher: false)
        #expect(fixture.model.reasoningEffort == .high)
        #expect(fixture.model.commandFeedback == L("ask.reasoning.snapped", AskReasoningEffort.max.label,
                                                   AskReasoningEffort.high.label))
        // A model without levels keeps the choice for the next one that has them.
        fixture.model.selectModel(plain.reference, launcher: false)
        #expect(fixture.model.reasoningEffort == .high)
        #expect(fixture.model.reasoningLevels(launcher: false).isEmpty)
        #expect(fixture.model.displayedReasoningEffort(launcher: false) == .providerDefault)
        // The command palette offers "Auto" plus the model's levels.
        fixture.model.selectModel(five.reference, launcher: false)
        let context = fixture.model.commandContext(launcher: false)
        #expect(context.reasoningLevels == AskReasoningEffort.levels)
        let names = AskCommandCatalog.submenu(.reasoning, context: context).map(\.name)
        #expect(names == ([.providerDefault] + AskReasoningEffort.levels).map(\.label))
    }

    @Test func newConversationRemembersChoicesWithoutFollowingOldConversations() async throws {
        let f = try fixture()
        defer { f.model.resetSession() }
        f.model.selectModel(five.reference, launcher: false)
        f.model.reasoningEffort = .max
        f.model.newConversation()
        #expect(f.model.modelReference(launcher: false) == five.reference)
        #expect(f.model.reasoningEffort == .max)

        await f.api.seed(AskConversation(id: "old", title: "Old", revision: 0, updatedAt: Date(), messages: []))
        await f.model.select("old")
        f.model.selectModel(three.reference, launcher: false)
        f.model.reasoningEffort = .low
        #expect(f.model.modelLibrary.defaultReference == five.reference)
        f.model.newConversation()
        #expect(f.model.modelReference(launcher: false) == five.reference)
        #expect(f.model.reasoningEffort == .max)
        let restored = AskModelLibrary(defaults: f.model.modelLibrary.defaults, automaticallyLoadsCatalog: false)
        let next = try AskTestFixture(modelLibrary: restored)
        defer { next.model.resetSession() }
        #expect(next.model.modelReference(launcher: false) == five.reference)
        #expect(next.model.reasoningEffort == .max)
    }

    @Test func launcherReasoningIsIndependentOfTheOpenConversation() async throws {
        let f = try fixture()
        defer { f.model.resetSession() }
        await f.api.seed(AskConversation(id: "old", title: "Old", revision: 0, updatedAt: Date(), messages: []))
        await f.model.select("old")
        f.model.reasoningEffort = .low
        f.model.selectModel(five.reference, launcher: true)
        f.model.selectReasoningEffort(.max, launcher: true)
        #expect(f.model.reasoningEffort == .low)
        #expect(f.model.displayedReasoningEffort(launcher: true) == .max)
        f.model.newConversation()
        #expect(f.model.reasoningEffort == .max)
    }

    @Test func modelPresentationSortsEnglishNamesAcrossCatalogs() throws {
        let f = try fixture()
        defer { f.model.resetSession() }
        let library = f.model.modelLibrary
        try library.replaceCloudModels([
            .init(id: "z", name: "Zeta"), .init(id: "g2", name: "GPT 6 Luna"),
            .init(id: "a", name: "alpha"), .init(id: "g1", name: "GPT 6 Astra")
        ])
        let expected = ["alpha", "GPT 6 Astra", "GPT 6 Luna", "Zeta"]
        #expect(library.providers.first(where: \.isCloud)?.models.map(\.name) == expected)
        #expect(library.selectableProviders(loggedIn: true, hasImage: false)
            .first(where: \.isCloud)?.models.map(\.name) == expected)
        try library.replaceRewriteModels([.init(id: "z", name: "Zeta"), .init(id: "a", name: "alpha")])
        let cloudProvider = library.providers.first(where: \.isCloud)
        let provider = try #require(cloudProvider)
        #expect(library.presentationProvider(provider, scenario: "rewrite").models.map(\.name) == ["alpha", "Zeta"])
    }

    @Test func sliderGeometryFillsTheTrackAtTheTopStop() {
        let width: CGFloat = 300
        let edge = AskEffortSlider.inset + AskEffortSlider.knob / 2
        #expect(AskEffortSlider.knobCenter(index: 0, count: 5, width: width) == edge)
        #expect(AskEffortSlider.knobCenter(index: 4, count: 5, width: width) == width - edge)
        #expect(AskEffortSlider.knobCenter(index: 0, count: 1, width: width) == width / 2)
        let top = AskEffortSlider.knobCenter(index: 2, count: 3, width: width)
        #expect(AskEffortSlider.fillWidth(knobCenter: top, width: width) == width)
        let first = AskEffortSlider.knobCenter(index: 0, count: 3, width: width)
        #expect(AskEffortSlider.fillWidth(knobCenter: first, width: width) == AskEffortSlider.knob + 2 * AskEffortSlider.inset)
        #expect(AskEffortSlider.index(at: 0, count: 5, width: width) == 0)
        #expect(AskEffortSlider.index(at: width, count: 5, width: width) == 4)
        #expect(AskEffortSlider.index(at: width / 2, count: 5, width: width) == 2)
        #expect(AskEffortSlider.index(at: 10, count: 1, width: width) == 0)
    }

    @Test func liquidNoiseIsStableAndInRange() {
        for index in 0 ..< AskLiquidFill.particleCount {
            let value = AskLiquidFill.noise(index, 2)
            #expect(value >= 0 && value < 1)
            #expect(value == AskLiquidFill.noise(index, 2))
        }
    }

    private func fits<V: View>(_ view: V) -> CGSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    @Test func cardPagesAndChipRender() throws {
        let fixture = try fixture()
        defer { fixture.model.resetSession() }
        let library = fixture.model.modelLibrary
        for effort in [AskReasoningEffort.providerDefault, .low, .max] {
            let card = fits(AskModelEffortCard(library: library, reference: .constant(five.reference),
                                               effort: .constant(effort), loggedIn: true))
            #expect(card.width == AskModelEffortCard.width)
            // Compact like the composer's other menus: title, model, slider and caption.
            #expect(card.height > 90 && card.height < 140)
        }
        let unsupported = fits(AskModelEffortCard(library: library, reference: .constant(plain.reference),
                                                  effort: .constant(.high), loggedIn: true))
        #expect(unsupported.height > 60)
        let models = fits(AskModelEffortCard(library: library, reference: .constant(five.reference),
                                             effort: .constant(.high), loggedIn: true, page: .models))
        #expect(models.height > unsupported.height)
        #expect(models.width == AskModelEffortCard.modelsWidth)
        let slider = fits(AskEffortSlider(levels: AskReasoningEffort.levels, effort: .constant(.max))
            .frame(width: 300))
        #expect(slider.height == AskEffortSlider.height)
        // The chip grows to show the level, and shows only the model for "Auto".
        let withLevel = fits(AskModelMenu(library: library, reference: .constant(five.reference), compact: true,
                                          cloudAvailable: true, effort: .constant(.max)))
        let auto = fits(AskModelMenu(library: library, reference: .constant(five.reference), compact: true,
                                     cloudAvailable: true, effort: .constant(.providerDefault)))
        #expect(withLevel.width > auto.width)
    }
}
