import AppKit
import Testing
@testable import Typeflux

@Suite("Release acceptance wording", .serialized, .exclusiveUIState)
@MainActor
struct ReleaseAcceptanceWordingTests {
    private static let expected: [(AppLanguage, String, String)] = [
        (AppLanguage.english, "Typeflux Settings", " parameters"),
        (AppLanguage.simplifiedChinese, "Typeflux 设置", " 参数"),
        (AppLanguage.traditionalChinese, "Typeflux 設定", " 參數"),
        (AppLanguage.japanese, "Typeflux 設定", " パラメータ"),
        (AppLanguage.korean, "Typeflux 설정", " 파라미터"),
    ]

    @Test func settingsMenuItemNamesTheApp() {
        withEachLanguage { _, settings, _ in
            // Never the wording macOS uses for its own System Settings.
            #expect(L("menu.settings") == settings)
        }
    }

    @Test func localModelParameterCountIsLocalized() {
        withEachLanguage { _, _, unit in
            for model in LocalSTTModel.allCases {
                let specs = model.specs
                #expect(specs.parameterCountText == specs.parameterValue + unit)
            }
        }
    }

    private func withEachLanguage(_ body: (AppLanguage, String, String) throws -> Void) rethrows {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        for (language, settings, unit) in Self.expected {
            AppLocalization.shared.setLanguage(language)
            try body(language, settings, unit)
        }
    }
}
