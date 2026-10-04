import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Five reasoning levels, offered per model; the composer's chip shows the model and
/// the level, and its card holds the slider and the model list.
@Suite("Ask effort picker", .serialized)
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
        let odd = RegisteredModel(id: "odd", name: "Odd", reference: "cloud:odd", reasoning: true, reasoningEfforts: ["turbo", "max"])
        #expect(AskReasoningEffort.levels(for: odd) == [.max])
        let unknown = RegisteredModel(id: "x", name: "X", reference: "cloud:x", reasoning: true, reasoningEfforts: ["turbo"])
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
        let json = #"{"id":"deep","name":"Deep","capabilities":{"reasoning":true},"reasoning_efforts":["low","high","max"]}"#
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
        try library.addModels([five, three, plain].map { var m = $0; m.scenarios = ["ask"]; return m },
                              providerID: "typefluxCloud")
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
            #expect(card.height > 100)
        }
        let unsupported = fits(AskModelEffortCard(library: library, reference: .constant(plain.reference),
                                                  effort: .constant(.high), loggedIn: true))
        #expect(unsupported.height > 60)
        let models = fits(AskModelEffortCard(library: library, reference: .constant(five.reference),
                                             effort: .constant(.high), loggedIn: true, page: .models))
        #expect(models.height > unsupported.height)
        let slider = fits(AskEffortSlider(levels: AskReasoningEffort.levels, effort: .constant(.max)).frame(width: 300))
        #expect(slider.height == AskEffortSlider.height)
        // The chip grows to show the level, and shows only the model for "Auto".
        let withLevel = fits(AskModelMenu(library: library, reference: .constant(five.reference), compact: true,
                                          cloudAvailable: true, effort: .constant(.max)))
        let auto = fits(AskModelMenu(library: library, reference: .constant(five.reference), compact: true,
                                     cloudAvailable: true, effort: .constant(.providerDefault)))
        #expect(withLevel.width > auto.width)
    }
}
