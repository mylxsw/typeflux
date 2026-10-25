import AppKit
@testable import Typeflux
import XCTest

final class RingSettingsPresentationTests: XCTestCase {
    func testWebURLAcceptsOnlyHTTPPages() {
        XCTAssertNotNil(RingSettingsPresentation.webURL("https://typeflux.app"))
        XCTAssertNotNil(RingSettingsPresentation.webURL(" http://a.b/c?d=e "))
        for text in ["", "typeflux.app", "file:///etc/hosts", "ftp://a.b", "https://localhost", "https://.app",
                     "https://app.", "javascript:alert(1)"] {
            XCTAssertNil(RingSettingsPresentation.webURL(text), text)
        }
        XCTAssertEqual(RingSettingsPresentation.title(forURL: "https://www.typeflux.app/x"), "typeflux.app")
        XCTAssertEqual(RingSettingsPresentation.title(forURL: "https://docs.typeflux.app"), "docs.typeflux.app")
        XCTAssertNil(RingSettingsPresentation.title(forURL: "nope"))
    }

    func testSliceLabelsWrapIntoTwoShortLines() {
        XCTAssertEqual(RingSettingsPresentation.sliceLabel(" Notes "), "Notes")
        XCTAssertEqual(RingSettingsPresentation.sliceLabel("语音输入"), "语音输入")
        XCTAssertEqual(RingSettingsPresentation.sliceLabel("翻译选中的文字内容"), "翻译选中的文字\n内容")
        XCTAssertEqual(RingSettingsPresentation.sliceLabel("非常非常长的一个操作名称啊啊啊"), "非常非常长的一\n个操作名称啊…")
        XCTAssertEqual(RingSettingsPresentation.sliceLabel("Screenshot Translation"), "Screenshot\nTranslation")
        XCTAssertEqual(RingSettingsPresentation.sliceLabel("Translate the selected text now"),
                       "Translate the\nselected text…")
        XCTAssertEqual(RingSettingsPresentation.sliceLabel("Supercalifragilistic"), "Supercalifragi\nlistic")
    }

    func testDirectionsGoClockwiseFromTheTop() {
        XCTAssertEqual((0 ..< 8).map { RingSettingsPresentation.direction(of: $0, count: 8) },
                       ["up", "upRight", "right", "downRight", "down", "downLeft", "left", "upLeft"].map {
                           L("ring.direction." + $0)
                       })
        XCTAssertEqual(RingSettingsPresentation.direction(of: 2, count: 4), L("ring.direction.down"))
        XCTAssertEqual(RingSettingsPresentation.direction(of: 0, count: 0), "")
    }

    func testSummaryNamesTheTarget() {
        let binding = HotkeyBinding(keyCode: 21, modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue))
        let cases: [(RingActionKind, String)] = [
            (.feature(.notes), RingFeature.notes.detail),
            (.keyword(keyword: "rw", pluginID: "p"), "rw · Polish"),
            (.app(bundleIdentifier: "com.apple.Safari", name: "Safari"), "Safari · com.apple.Safari"),
            (.keys(binding), HotkeyFormat.display(binding)),
            (.system(.mute), RingSystemAction.mute.detail),
            (.shortcut(name: "Pomodoro"), "Pomodoro"),
            (.url("https://a.b"), "https://a.b"),
            (.folder(path: "~/x"), "~/x")
        ]
        for (kind, expected) in cases {
            let summary = RingSettingsPresentation.summary(of: RingAction(
                kind: kind,
                title: "t",
                symbol: "s"
            )) { _, _ in
                "Polish"
            }
            XCTAssertEqual(summary, expected)
        }
        XCTAssertEqual(RingSettingsPresentation.summary(of: RingAction(kind: .keyword(keyword: "rw", pluginID: "p"),
                                                                       title: "t", symbol: "s")), "rw")
    }

    func testEveryEnumHasTextAndSymbols() {
        for feature in RingFeature.allCases {
            XCTAssertFalse(feature.title.hasPrefix("ring."), feature.rawValue)
            XCTAssertFalse(feature.detail.hasPrefix("ring."), feature.rawValue)
            XCTAssertNotNil(NSImage(systemSymbolName: feature.symbol, accessibilityDescription: nil), feature.symbol)
        }
        for system in RingSystemAction.allCases {
            XCTAssertFalse(system.title.hasPrefix("ring."), system.rawValue)
            XCTAssertFalse(system.detail.hasPrefix("ring."), system.rawValue)
            XCTAssertNotNil(NSImage(systemSymbolName: system.symbol, accessibilityDescription: nil), system.symbol)
        }
        for type in RingActionType.allCases {
            XCTAssertEqual(type.id, type.rawValue)
            XCTAssertFalse(type.title.hasPrefix("ring."), type.rawValue)
            XCTAssertFalse(type.targetLabel.hasPrefix("ring."), type.rawValue)
            XCTAssertNotNil(NSImage(systemSymbolName: type.symbol, accessibilityDescription: nil), type.symbol)
        }
        for group in ["input", "screenshot", "windows", "appearance", "desktop", "security", "keywords", "apps",
                      "commonKeys", "shortcuts", "folders", "typed"] {
            XCTAssertFalse(L("ring.library.group." + group).hasPrefix("ring."), group)
        }
        for style in RingStyle.allCases {
            XCTAssertEqual(style.id, style.rawValue)
            XCTAssertFalse(style.title.hasPrefix("ring."), style.rawValue)
        }
        for symbol in RingSettingsPresentation.symbolChoices + [RingSettingsPresentation.symbol] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testFeaturesWithAShortcutReuseItsHandler() {
        XCTAssertEqual(RingFeature.allCases.compactMap(\.shortcutAction), [
            .openChat, .screenshotText, .screenshotTranslation, .translate, .openNotes, .openWordBook, .openStudio
        ])
        for feature in [RingFeature.dictation, .ask, .screenshot, .clipboard, .persona] {
            XCTAssertNil(feature.shortcutAction, feature.rawValue)
        }
    }

    func testSymbolChoicesAreUniqueAndCoverCommonShortcutActions() {
        let symbols = RingSettingsPresentation.symbolChoices
        XCTAssertEqual(Set(symbols).count, symbols.count)
        for symbol in ["arrow.clockwise", "chevron.left", "plus.square", "xmark.square",
                       "doc.on.doc", "scissors", "play", "display", "folder.badge.plus"] {
            XCTAssertTrue(symbols.contains(symbol), symbol)
        }
    }

    func testPickerKeysAreDistinct() {
        let binding = HotkeyBinding(keyCode: 21, modifierFlags: 0)
        let kinds: [RingActionKind] = RingFeature.allCases.map { .feature($0) }
            + RingSystemAction.allCases.map { .system($0) }
            + [.keyword(keyword: "RW", pluginID: "p"), .app(bundleIdentifier: "a", name: "A"), .keys(binding),
               .shortcut(name: "s"), .url("u"), .folder(path: "f")]
        XCTAssertEqual(Set(kinds.map(\.pickerKey)).count, kinds.count)
        XCTAssertEqual(RingActionKind.keyword(keyword: "RW", pluginID: "p").pickerKey, "keyword.p/rw")
    }

    func testIssuesNameWhatCanNoLongerRun() {
        func issue(_ kind: RingActionKind, keyword: Bool = true, app: Bool = true, folder: Bool = true) -> String? {
            RingSettingsPresentation.issue(of: RingAction(kind: kind, title: "T", symbol: "star"),
                                           keywordExists: { _, _ in keyword }, appExists: { _ in app },
                                           folderExists: { _ in folder })
        }
        XCTAssertNil(issue(.feature(.notes), keyword: false, app: false, folder: false))
        XCTAssertNil(issue(.system(.mute)))
        XCTAssertNil(issue(.shortcut(name: "x")))
        XCTAssertNil(issue(.keys(HotkeyBinding(keyCode: 1, modifierFlags: 0))))
        XCTAssertNil(issue(.keyword(keyword: "fy", pluginID: "p")))
        XCTAssertEqual(issue(.keyword(keyword: "fy", pluginID: "p"), keyword: false),
                       L("ring.issue.keywordMissing", "fy"))
        XCTAssertNil(issue(.app(bundleIdentifier: "a.b", name: "Sketch")))
        XCTAssertEqual(issue(.app(bundleIdentifier: "a.b", name: "Sketch"), app: false),
                       L("ring.error.appMissing", "Sketch"))
        XCTAssertNil(issue(.url("https://typeflux.app")))
        XCTAssertEqual(issue(.url("typeflux")), L("ring.error.invalidURL"))
        XCTAssertNil(issue(.folder(path: "~/Downloads")))
        XCTAssertEqual(issue(.folder(path: "~/Gone"), folder: false), L("ring.error.folderMissing", "~/Gone"))
        var checked = ""
        _ = RingSettingsPresentation.issue(of: RingAction(kind: .folder(path: "~/Docs"), title: "", symbol: ""),
                                           keywordExists: { _, _ in true }, appExists: { _ in true },
                                           folderExists: { checked = $0; return true })
        XCTAssertEqual(checked, NSHomeDirectory() + "/Docs", "the tilde is expanded before checking")
    }
}
