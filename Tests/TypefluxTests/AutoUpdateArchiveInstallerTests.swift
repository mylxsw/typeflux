@testable import Typeflux
import XCTest

final class AutoUpdateArchiveInstallerTests: XCTestCase {
    func testArchiveKindDetectsDMGCaseInsensitively() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/releases/Typeflux.DMG?download=1"))

        XCTAssertEqual(AutoUpdateArchiveInstaller.archiveKind(for: url), .dmg)
    }

    func testArchiveKindDefaultsToZip() throws {
        let zipURL = try XCTUnwrap(URL(string: "https://example.com/releases/Typeflux.zip"))
        let extensionlessURL = try XCTUnwrap(URL(string: "https://example.com/api/download/latest"))

        XCTAssertEqual(AutoUpdateArchiveInstaller.archiveKind(for: zipURL), .zip)
        XCTAssertEqual(AutoUpdateArchiveInstaller.archiveKind(for: extensionlessURL), .zip)
    }

    func testShellSingleQuotedEscapesApostrophes() {
        let quoted = AutoUpdateArchiveInstaller.shellSingleQuoted("/Applications/Typeflux Bob's.app")

        XCTAssertEqual(quoted, "'/Applications/Typeflux Bob'\\''s.app'")
    }

    func testRelaunchScriptQuotesPathsAndRelaunchesWhenRequested() {
        let script = AutoUpdateArchiveInstaller.relaunchScript(
            currentAppURL: URL(fileURLWithPath: "/Applications/Typeflux Bob's.app"),
            newAppURL: URL(fileURLWithPath: "/tmp/update path/Typeflux.app"),
            cleanupURL: URL(fileURLWithPath: "/tmp/update path"),
            currentProcessIdentifier: 12345,
            relaunch: true
        )

        XCTAssertTrue(script.contains("set -e"))
        XCTAssertTrue(script.contains("current_app='/Applications/Typeflux Bob'\\''s.app'"))
        XCTAssertTrue(script.contains("new_app='/tmp/update path/Typeflux.app'"))
        XCTAssertTrue(script.contains("cleanup_dir='/tmp/update path'"))
        XCTAssertTrue(script.contains("current_pid='12345'"))
        XCTAssertTrue(script.contains("kill -0 \"$current_pid\""))
        XCTAssertTrue(script.contains("backup_app=\"${current_app}.typeflux-backup.$$\""))
        XCTAssertTrue(script.contains("mv \"$current_app\" \"$backup_app\""))
        XCTAssertTrue(script.contains("if ! mv \"$new_app\" \"$current_app\"; then"))
        XCTAssertTrue(script.contains("restore_current"))
        XCTAssertTrue(script.contains("open \"$current_app\""))
        XCTAssertTrue(script.contains("rm -rf \"$cleanup_dir\""))
    }

    func testRelaunchScriptOmitsOpenWhenRelaunchDisabled() {
        let script = AutoUpdateArchiveInstaller.relaunchScript(
            currentAppURL: URL(fileURLWithPath: "/Applications/Typeflux.app"),
            newAppURL: URL(fileURLWithPath: "/tmp/Typeflux.app"),
            relaunch: false
        )

        XCTAssertFalse(script.contains("\nopen "))
    }

    func testRelaunchScriptDoesNotDeleteCurrentAppBeforeReplacement() {
        let script = AutoUpdateArchiveInstaller.relaunchScript(
            currentAppURL: URL(fileURLWithPath: "/Applications/Typeflux.app"),
            newAppURL: URL(fileURLWithPath: "/tmp/Typeflux.app"),
            relaunch: false
        )

        XCTAssertFalse(script.contains("rm -rf \"$current_app\""))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "mv \"$current_app\" \"$backup_app\"")?.lowerBound),
            try XCTUnwrap(script.range(of: "if ! mv \"$new_app\" \"$current_app\"; then")?.lowerBound)
        )
    }

    func testFindAppBundleSearchesNestedDirectories() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-updater-test-\(UUID().uuidString)")
        let appURL = rootURL
            .appendingPathComponent("nested")
            .appendingPathComponent("Typeflux.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let found = try AutoUpdateArchiveInstaller.findAppBundle(in: rootURL)

        XCTAssertEqual(found.standardizedFileURL, appURL.standardizedFileURL)
    }
}
