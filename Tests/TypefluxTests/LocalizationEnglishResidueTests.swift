import Foundation
@testable import Typeflux
import XCTest

/// Releases must not fall back to English: a translated language may repeat an English value only
/// where `Fixtures/localization-english-allowlist.json` records why.
final class LocalizationEnglishResidueTests: XCTestCase {
    private struct Allowance: Decodable {
        let table: String
        let key: String
        let languages: [String]
        let reason: String
    }

    private struct Entry: Hashable, CustomStringConvertible {
        let language: String
        let table: String
        let key: String

        var description: String { "\(language) \(table) \(key)" }
    }

    private static let languages: [AppLanguage] = [
        .japanese, .korean, .traditionalChinese, .simplifiedChinese
    ]

    func testTranslatedValuesDifferFromEnglishUnlessAllowed() throws {
        let allowed = try Set(allowances().flatMap { allowance in
            allowance.languages.map { Entry(language: $0, table: allowance.table, key: allowance.key) }
        })
        var identical = Set<Entry>()
        for table in try tableNames() {
            let english = try strings(table: table, language: .english)
            for language in Self.languages {
                for (key, value) in try strings(table: table, language: language) where english[key] == value {
                    identical.insert(Entry(language: language.rawValue, table: table, key: key))
                }
            }
        }

        XCTAssertEqual(report(identical.subtracting(allowed)), "",
                       "Translate these values, or allow them with a reason")
        XCTAssertEqual(report(allowed.subtracting(identical)), "",
                       "Remove allowlist entries that no longer repeat English")
    }

    /// An outdated English sentence differs from the current one, so the comparison above misses it.
    func testTranslatedValuesAreNotOutdatedEnglishSentences() throws {
        let nativeScript = "[\\u3040-\\u30ff\\u3400-\\u9fff\\uac00-\\ud7af]"
        let englishRun = "(?:\\b[A-Za-z]{2,}\\b[ ,]+){3}\\b[A-Za-z]{2,}\\b"
        var outdated = Set<Entry>()
        for table in try tableNames() {
            let english = try strings(table: table, language: .english)
            for language in Self.languages {
                for (key, value) in try strings(table: table, language: language)
                    where english[key] != value
                    && value.range(of: nativeScript, options: .regularExpression) == nil
                    && value.range(of: englishRun, options: .regularExpression) != nil {
                    outdated.insert(Entry(language: language.rawValue, table: table, key: key))
                }
            }
        }

        XCTAssertEqual(report(outdated), "")
    }

    func testEveryAllowanceIsUniqueAndExplained() throws {
        let allowances = try allowances()
        let names = Set(Self.languages.map(\.rawValue))

        XCTAssertEqual(Set(allowances.map { "\($0.table) \($0.key)" }).count, allowances.count)
        for allowance in allowances {
            XCTAssertFalse(allowance.reason.trimmingCharacters(in: .whitespaces).isEmpty, allowance.key)
            XCTAssertFalse(allowance.languages.isEmpty, allowance.key)
            XCTAssertTrue(Set(allowance.languages).isSubset(of: names), allowance.key)
        }
    }

    private func allowances() throws -> [Allowance] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/localization-english-allowlist.json")
        return try JSONDecoder().decode([Allowance].self, from: Data(contentsOf: url))
    }

    private func tableNames() throws -> [String] {
        let names = try XCTUnwrap(bundle(for: .english).urls(forResourcesWithExtension: "strings",
                                                             subdirectory: nil))
            .map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertTrue(names.contains("Localizable"))
        XCTAssertTrue(names.contains("OnboardingShared"))
        return names.sorted()
    }

    private func strings(table: String, language: AppLanguage) throws -> [String: String] {
        let url = try XCTUnwrap(bundle(for: language).url(forResource: table, withExtension: "strings"),
                                "Missing \(table) in \(language.rawValue)")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url),
            options: [], format: nil) as? [String: String])
    }

    private func bundle(for language: AppLanguage) throws -> Bundle {
        let path = try XCTUnwrap(
            language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first,
            "Missing bundle path for \(language.rawValue)"
        )
        return try XCTUnwrap(Bundle(path: path), "Missing bundle for \(language.rawValue)")
    }

    private func report(_ entries: Set<Entry>) -> String {
        entries.map(\.description).sorted().joined(separator: "\n")
    }
}
