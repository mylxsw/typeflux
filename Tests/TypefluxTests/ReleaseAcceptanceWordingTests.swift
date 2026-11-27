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

    @Test func switchDownloadFailuresAskTheUserToCheckTheNetwork() {
        let failures: [Error] = [
            ClassicPackageDownloadError.httpStatus(404),
            URLError(.notConnectedToInternet),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            CloudRequestExecutorError.allEndpointsFailed(lastError: URLError(.cannotConnectToHost)),
            CloudRequestExecutorError.noEndpointsAvailable,
        ]
        withEachLanguage { language, _, _ in
            let expected = L("classic.switch.error.download")
            #expect(expected != "classic.switch.error.download")
            #expect(expected.contains("Typeflux Classic"))
            #expect(expected != L("updater.download.failed"))
            for failure in failures {
                #expect(ClassicSwitchController.message(for: failure) == expected, "\(language.rawValue): \(failure)")
            }
        }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        #expect(L("classic.switch.error.download") == "无法下载 Typeflux Classic，请检查网络后重试。")
    }

    @Test func otherSwitchFailuresKeepTheirOwnMessage() {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        #expect(ClassicSwitchController.message(for: ClassicSwitchFlowError.featuresBusy) == L("classic.switch.error.busy"))
        let disk = CocoaError(.fileWriteOutOfSpace)
        #expect(ClassicSwitchController.message(for: disk) == disk.localizedDescription)
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
