import AppKit
@testable import Typeflux
import XCTest

final class ClipboardAppIconProviderTests: XCTestCase {
    private let appIcon = NSImage(size: NSSize(width: 16, height: 16))
    private let ownIcon = NSImage(size: NSSize(width: 32, height: 32))

    private func provider(
        installed: Set<String>, lookups: @escaping (String) -> Void = { _ in }
    ) -> ClipboardAppIconProvider {
        ClipboardAppIconProvider(
            applicationURL: { bundleID in
                lookups(bundleID)
                return installed.contains(bundleID) ? URL(fileURLWithPath: "/Applications/\(bundleID).app") : nil
            },
            iconForApplication: { [appIcon] _ in appIcon },
            ownIcon: { [ownIcon] in ownIcon }
        )
    }

    func testCopiedEntriesUseTheirSourceAppIcon() {
        let provider = provider(installed: ["com.apple.finder"])
        let entry = ClipboardTestSupport.entry(.text, sourceBundleID: "com.apple.finder", sourceAppName: "Finder")
        XCTAssertTrue(provider.icon(for: entry) === appIcon)
    }

    func testVoiceEntriesUseTypefluxIcon() {
        let provider = provider(installed: [])
        XCTAssertTrue(provider.icon(for: ClipboardTestSupport.entry(.voice)) === ownIcon)
    }

    func testUnknownOrUninstalledSourcesHaveNoIcon() {
        let provider = provider(installed: [])
        XCTAssertNil(provider.icon(for: ClipboardTestSupport.entry(.image)))
        XCTAssertNil(provider.icon(forBundleID: ""))
        XCTAssertNil(provider.icon(forBundleID: "com.example.removed"))
    }

    func testLookupsAreCachedIncludingMisses() {
        var lookups: [String] = []
        let provider = provider(installed: ["com.apple.finder"]) { lookups.append($0) }
        for _ in 0 ..< 3 {
            XCTAssertNotNil(provider.icon(forBundleID: "com.apple.finder"))
            XCTAssertNil(provider.icon(forBundleID: "com.example.removed"))
        }
        XCTAssertEqual(lookups, ["com.apple.finder", "com.example.removed"])
    }

    func testSharedProviderResolvesInstalledSystemApps() {
        XCTAssertNotNil(ClipboardAppIconProvider.shared.icon(forBundleID: "com.apple.finder"))
        XCTAssertNotNil(ClipboardAppIconProvider.shared.icon(for: ClipboardTestSupport.entry(.voice)))
    }
}
