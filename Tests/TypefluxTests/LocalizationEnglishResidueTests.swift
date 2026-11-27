import Foundation
@testable import Typeflux
import XCTest

/// Releases must not fall back to another language: a translated language may repeat an English value
/// only where `Fixtures/localization-english-allowlist.json` records why, and Traditional Chinese may
/// not use the Simplified-only characters in `Fixtures/localization-simplified-characters.json`.
final class LocalizationEnglishResidueTests: XCTestCase {
    private struct Allowance: Decodable {
        let table: String
        let key: String
        let languages: [String]
        let reason: String
    }

    private struct SimplifiedCharacters: Decodable {
        struct Allowance: Decodable {
            let table: String
            let key: String
            let reason: String
        }

        let characters: String
        let allowed: [Allowance]
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

    func testTraditionalChineseHasNoSimplifiedOnlyCharacters() throws {
        let fixture: SimplifiedCharacters = try decodeFixture("localization-simplified-characters.json")
        let simplified = Set(fixture.characters)
        let language = AppLanguage.traditionalChinese
        let allowed = Set(fixture.allowed.map {
            Entry(language: language.rawValue, table: $0.table, key: $0.key)
        })
        var found: [Entry: String] = [:]
        for table in try tableNames() {
            for (key, value) in try strings(table: table, language: language) {
                let characters = String(value.filter(simplified.contains))
                if !characters.isEmpty {
                    found[Entry(language: language.rawValue, table: table, key: key)] = characters
                }
            }
        }

        let unexpected = found.filter { !allowed.contains($0.key) }
            .map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        XCTAssertEqual(unexpected, "", "Write these values in Traditional Chinese")
        XCTAssertEqual(report(allowed.subtracting(found.keys)), "",
                       "Remove allowances that no longer use Simplified characters")
    }

    func testSimplifiedCharacterListSeparatesTheTwoScripts() throws {
        let fixture: SimplifiedCharacters = try decodeFixture("localization-simplified-characters.json")
        let simplified = Set(fixture.characters)

        XCTAssertTrue(Set("设档视频权浏览开简体").isSubset(of: simplified))
        // Includes characters both scripts share, which must not be reported.
        XCTAssertTrue(Set("設檔視頻權瀏覽開簡體台里后面只").isDisjoint(with: simplified))
        XCTAssertEqual(Set(fixture.allowed.map { "\($0.table) \($0.key)" }).count, fixture.allowed.count)
        for allowance in fixture.allowed {
            XCTAssertFalse(allowance.reason.trimmingCharacters(in: .whitespaces).isEmpty, allowance.key)
        }
    }

    private func allowances() throws -> [Allowance] {
        try decodeFixture("localization-english-allowlist.json")
    }

    private func decodeFixture<Value: Decodable>(_ name: String) throws -> Value {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/" + name)
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
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
