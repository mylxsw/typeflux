import Foundation
import Testing
@testable import Typeflux

@Suite("World clock launcher model", .serialized, .exclusiveUIState)
@MainActor
struct WorldClockLauncherModelTests {
    static func model(_ text: String = "", options: [String: String] = WorldClockFixtures.listOptions)
        -> WorldClockLauncherModel {
        let model = WorldClockLauncherModel(directory: WorldClockFixtures.directory, clock: { WorldClockFixtures.now },
                                            localZone: { WorldClockFixtures.shanghai })
        model.activate(text: text, options: options, language: .english)
        return model
    }

    private func withEnglish(_ body: () throws -> Void) rethrows {
        let old = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(old) }
        try body()
    }

    @Test func `the list starts with the local zone and follows the clock`() {
        withEnglish {
            let model = Self.model()
            defer { model.close() }
            #expect(model.listCities.map(\.id) == ["shanghai", "newyork", "london", "tokyo"])
            #expect(model.rows().map(\.isLocal) == [true, false, false, false])
            #expect(model.isAtNow && model.moment == WorldClockFixtures.now)
            #expect(model.primaryTitle == "Copy" && model.primaryEnabled)
            #expect(model.handle(.enter, inputEmpty: true) == .copy("Shanghai Thu, Oct 22 18:24"))
            #expect(model.handle(.down, inputEmpty: true) == .handled)
            #expect(model.chosenCity?.id == "newyork")
            #expect(model.handle(.commandC, inputEmpty: true) == .copy("New York Thu, Oct 22 06:24"))
            #expect(model.handle(.optionEnter, inputEmpty: true) == .insert("New York Thu, Oct 22 06:24"))
            for _ in 0 ..< 6 { _ = model.handle(.down, inputEmpty: true) }
            #expect(model.selection == 3)
            for _ in 0 ..< 6 { _ = model.handle(.up, inputEmpty: true) }
            #expect(model.selection == 0)
        }
    }

    @Test func `arrows move the time in round steps and command T returns`() {
        withEnglish {
            let model = Self.model()
            defer { model.close() }
            #expect(model.handle(.right, inputEmpty: true) == .handled)
            #expect(model.moment == WorldClockFixtures.utc("2026-10-22T10:30:00Z"))
            #expect(!model.isAtNow)
            _ = model.handle(.left, inputEmpty: true)
            _ = model.handle(.left, inputEmpty: true)
            #expect(model.moment == WorldClockFixtures.utc("2026-10-22T09:30:00Z"))
            _ = model.handle(.commandRight, inputEmpty: true)
            #expect(model.moment == WorldClockFixtures.utc("2026-10-23T09:30:00Z"))
            _ = model.handle(.commandLeft, inputEmpty: true)
            #expect(model.handle(.left, inputEmpty: false) == .unhandled)
            #expect(model.handle(.escape, inputEmpty: true) == .handled)
            #expect(model.isAtNow)
            #expect(model.handle(.escape, inputEmpty: true) == .unhandled)
            model.moveTo(fraction: 0.5)
            #expect(model.moment == WorldClockFixtures.utc("2026-10-22T04:00:00Z"))
            #expect(model.handle(.commandT, inputEmpty: true) == .handled)
            #expect(model.isAtNow)
            #expect(model.handle(.commandT, inputEmpty: false) == .clearInput)
            #expect(model.handle(.escape, inputEmpty: false) == .clearInput)
            #expect(model.handle(.commandEnter, inputEmpty: true) == .handled)
            #expect(model.handle(.number(1), inputEmpty: true) == .unhandled)
        }
    }

    @Test func `cities are removed restored and reordered`() throws {
        try withEnglish {
            let model = Self.model()
            defer { model.close() }
            model.select(2)
            guard case let .save(removed, clear, message) = model.handle(.commandDelete, inputEmpty: true) else {
                Issue.record("remove"); return
            }
            #expect(removed.cityIDs == ["newyork", "tokyo"] && !clear && message.contains("London"))
            #expect(model.removed?.id == "london")
            guard case let .save(restored, _, _) = model.handle(.commandZ, inputEmpty: true) else {
                Issue.record("undo"); return
            }
            #expect(restored.cityIDs == ["newyork", "london", "tokyo"] && model.chosenCity?.id == "london")
            #expect(model.handle(.commandZ, inputEmpty: true) == .unhandled)
            guard case let .save(moved, _, _) = model.handle(.optionUp, inputEmpty: true) else {
                Issue.record("move"); return
            }
            #expect(moved.cityIDs == ["london", "newyork", "tokyo"] && model.chosenCity?.id == "london")
            #expect(model.handle(.optionUp, inputEmpty: true) == .handled)
            model.select(0)
            #expect(model.handle(.commandDelete, inputEmpty: true) == .handled)
            #expect(model.handle(.optionDown, inputEmpty: true) == .handled)
            let labelled = try #require(WorldClockPreferences(options: [
                WorldClockPreferences.citiesOption: #"["newyork"]"#,
                WorldClockPreferences.labelsOption: #"{"newyork":"Maya"}"#
            ]) as WorldClockPreferences?)
            var options: [String: String] = [:]
            labelled.write(into: &options)
            let other = Self.model(options: options)
            defer { other.close() }
            other.select(1)
            _ = other.handle(.commandDelete, inputEmpty: true)
            guard case let .save(back, _, _) = other.handle(.commandZ, inputEmpty: true) else {
                Issue.record("label undo"); return
            }
            #expect(back.labels["newyork"] == "Maya")
            other.updatePreferences(options: [:])
            #expect(other.selection <= other.listCities.count - 1)
        }
    }

    @Test func `search adds a city or copies one already listed`() {
        withEnglish {
            let model = Self.model("kathmandu")
            defer { model.close() }
            #expect(model.chosenCity?.id == "kathmandu")
            #expect(model.primaryTitle == "Add to World Clock")
            guard case let .save(added, clear, _) = model.handle(.enter, inputEmpty: false) else {
                Issue.record("add"); return
            }
            #expect(added.cityIDs.last == "kathmandu" && clear)
            #expect(model.query == .list && model.chosenCity?.id == "kathmandu")
            model.update("london")
            #expect(model.primaryTitle == "Copy")
            #expect(model.handle(.enter, inputEmpty: false) == .copy("London Thu, Oct 22 11:24"))
            #expect(model.add(WorldClockFixtures.directory.city(id: "london")!) == .handled)
            model.update("lon")
            #expect(model.handle(.down, inputEmpty: false) == .handled)
            #expect(model.rowCities.count == model.searchResults.count)
        }
    }

    @Test func `conversions meetings and timestamps copy what they show`() {
        withEnglish {
            let model = Self.model("15:00 London to Tokyo")
            defer { model.close() }
            #expect(model.primaryTitle == "Copy Result")
            #expect(model.handle(.enter, inputEmpty: false)
                == .copy("London Thu, Oct 22 15:00 = Tokyo Thu, Oct 22 23:00"))
            #expect(model.rowCities.prefix(2).map(\.id) == ["london", "tokyo"])
            #expect(model.handle(.left, inputEmpty: false) == .unhandled)
            #expect(model.handle(.commandLeft, inputEmpty: false) == .unhandled)

            model.update("9pm")
            #expect(model.copyText == "Shanghai Thu, Oct 22 21:00")

            model.update("Beijing New York London")
            #expect(model.primaryTitle == "Copy Times")
            let first = model.chosenMeeting?.start
            #expect(model.handle(.tab, inputEmpty: false) == .handled)
            #expect(model.suggestion == 1)
            _ = model.handle(.shiftTab, inputEmpty: false)
            #expect(model.suggestion == 0)
            #expect(model.handle(.optionRight, inputEmpty: false) == .handled)
            #expect(model.chosenMeeting?.start == first?.addingTimeInterval(1800))
            #expect(model.copyText?.hasPrefix("Meeting time: Beijing") == true)
            #expect(model.copyText?.contains("EDT") == true)
            model.chooseSuggestion(9)
            #expect(model.suggestion == 0)
            model.chooseSuggestion(2)
            #expect(model.nudge == 0 && model.shownMoment == model.chosenMeeting?.start)
            #expect(model.handle(.optionUp, inputEmpty: false) == .unhandled)

            model.update("1792405440")
            #expect(model.handle(.commandC, inputEmpty: false) == .copy("2026-10-19T10:24:00Z"))
            #expect(model.handle(.enter, inputEmpty: false) == .copy("Shanghai Mon, Oct 19 18:24"))
            #expect(model.rowCities.count == 4)

            model.update("Atlantis")
            #expect(!model.primaryEnabled && model.copyText == nil && model.rows().isEmpty)
            #expect(model.handle(.enter, inputEmpty: false) == .handled)
            #expect(model.handle(.optionLeft, inputEmpty: false) == .unhandled)
        }
    }
}
