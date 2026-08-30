import Foundation
import XCTest

final class AccountViewCloudDataSyncVisibilityTests: XCTestCase {
    func testCloudDataSyncEntryPointsRemainCommentedOutForRelease() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let accountViewURL = repositoryRoot
            .appendingPathComponent("Sources/Typeflux/Auth/AccountView.swift")
        let source = try String(contentsOf: accountViewURL, encoding: .utf8)
        let activeLines = source.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }

        XCTAssertFalse(
            activeLines.contains { $0.contains("cloudDataSync") },
            "The account page must not expose cloud data sync in this release."
        )
        XCTAssertTrue(source.contains("// cloudDataSyncSection"))
        XCTAssertTrue(source.contains("Cloud data sync is not stable enough for this release"))
    }
}
