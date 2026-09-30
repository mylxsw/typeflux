import Foundation
import Testing
@testable import Typeflux

@Suite("Ask shortcut hint")
struct AskShortcutHintTests {
    private func keys(_ clauses: [[AskHintSegment]]) -> [String] {
        clauses.flatMap { $0 }.compactMap { segment in
            if case let .key(value) = segment { return value }
            return nil
        }
    }

    @Test func keysComeFromTheConfiguredShortcuts() {
        let clauses = AskPresentation.shortcutHint(summon: .defaultAsk, voice: .defaultActivation)
        #expect(clauses.count == 2)
        #expect(keys(clauses) == [HotkeyFormat.display(.defaultAsk), HotkeyFormat.display(.defaultActivation)])
        // The default summon shortcut is not Fn; the old hint always said it was.
        #expect(!HotkeyFormat.display(.defaultAsk).contains("Fn"))
    }

    @Test func rebindingTheVoiceKeyChangesTheHint() {
        let rightOption = HotkeyBinding.rightOptionActivation
        let clauses = AskPresentation.shortcutHint(summon: .defaultAsk, voice: rightOption)
        #expect(keys(clauses).last == HotkeyFormat.display(rightOption))
        #expect(keys(clauses).last != HotkeyFormat.display(.defaultActivation))
    }

    @Test func clausesKeepTheirLocalizedWordsAroundTheKey() {
        let clause = AskPresentation.shortcutHint(summon: nil, voice: .defaultActivation)[0]
        let words = clause.compactMap { segment -> String? in
            if case let .text(value) = segment { return value }
            return nil
        }
        let expected = [L("ask.empty.voice.before"), L("ask.empty.voice.after")].filter { !$0.isEmpty }
        #expect(words == expected)
        #expect(clause.contains(.key(HotkeyFormat.display(.defaultActivation))))
    }

    @Test func unsetShortcutsDegradeGracefully() {
        #expect(AskPresentation.shortcutHint(summon: nil, voice: .defaultActivation).count == 1)
        let noVoice = AskPresentation.shortcutHint(summon: nil, voice: nil)
        #expect(noVoice == [[.text(L("ask.empty.voice.button"))]])
        #expect(keys(noVoice).isEmpty)
    }

    @Test func spokenHintReadsKeysInline() {
        let clauses: [[AskHintSegment]] = [[.text("Press"), .key("⌘ Space"), .text("to summon")],
                                           [.key("Fn"), .text("to dictate")]]
        #expect(AskPresentation.spokenHint(clauses) == "Press ⌘ Space to summon · Fn to dictate")
        #expect(AskPresentation.spokenHint([]) == "")
    }

    @Test func everyLocalizationDefinesTheHintWords() throws {
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            for key in ["ask.empty.summon.after", "ask.empty.voice.after", "ask.empty.voice.button"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                #expect(value != key && !value.isEmpty, "Missing \(key) for \(language.rawValue)")
            }
            let old = bundle.localizedString(forKey: "ask.empty.hint", value: nil, table: nil)
            #expect(old == "ask.empty.hint", "Stale hardcoded-Fn hint left in \(language.rawValue)")
        }
    }
}
