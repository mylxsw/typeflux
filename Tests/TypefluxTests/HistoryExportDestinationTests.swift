import XCTest
@testable import Typeflux

final class HistoryExportDestinationTests: XCTestCase {
    private var testDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryExportDestinationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testDir {
            try? FileManager.default.removeItem(at: testDir)
        }
        testDir = nil
        try super.tearDownWithError()
    }

    func testMoveExportMovesFileIntoSelectedDirectory() throws {
        let sourceURL = testDir.appendingPathComponent("history-123.md")
        let destinationDirectoryURL = testDir.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
        try "export body".write(to: sourceURL, atomically: true, encoding: .utf8)

        let destinationURL = try HistoryExportDestination.moveExport(
            at: sourceURL,
            to: destinationDirectoryURL,
        )

        XCTAssertEqual(destinationURL, destinationDirectoryURL.appendingPathComponent("history-123.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "export body")
    }

    func testMoveExportReplacesExistingFileInSelectedDirectory() throws {
        let sourceURL = testDir.appendingPathComponent("history-123.md")
        let destinationDirectoryURL = testDir.appendingPathComponent("exports", isDirectory: true)
        let destinationURL = destinationDirectoryURL.appendingPathComponent("history-123.md")
        try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
        try "old body".write(to: destinationURL, atomically: true, encoding: .utf8)
        try "new body".write(to: sourceURL, atomically: true, encoding: .utf8)

        let resultURL = try HistoryExportDestination.moveExport(
            at: sourceURL,
            to: destinationDirectoryURL,
        )

        XCTAssertEqual(resultURL, destinationURL)
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "new body")
    }

    func testMoveExportReturnsExistingFileWhenDirectoryAlreadyContainsSource() throws {
        let sourceURL = testDir.appendingPathComponent("history-123.md")
        try "export body".write(to: sourceURL, atomically: true, encoding: .utf8)

        let destinationURL = try HistoryExportDestination.moveExport(
            at: sourceURL,
            to: testDir,
        )

        XCTAssertEqual(destinationURL, sourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "export body")
    }
}
