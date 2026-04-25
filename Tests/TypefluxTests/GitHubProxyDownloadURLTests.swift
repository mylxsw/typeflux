@testable import Typeflux
import XCTest

final class GitHubProxyDownloadURLTests: XCTestCase {
    func testBuildsProxyURLForGitHubDownload() throws {
        let original = try XCTUnwrap(URL(
            string: "https://github.com/mylxsw/typeflux/releases/download/pre-release-48/Typeflux-pre-release-full.dmg"
        ))

        let proxied = try XCTUnwrap(GitHubProxyDownloadURL.proxyURL(for: original))

        XCTAssertEqual(
            proxied.absoluteString,
            "https://gh-proxy.com/https://github.com/mylxsw/typeflux/releases/download/pre-release-48/Typeflux-pre-release-full.dmg"
        )
    }

    func testBuildsProxyURLForGitHubDownloadWithQuery() throws {
        let original = try XCTUnwrap(URL(
            string: "https://github.com/mylxsw/typeflux/releases/download/v1/Typeflux.zip?download=1"
        ))

        let proxied = try XCTUnwrap(GitHubProxyDownloadURL.proxyURL(for: original))

        XCTAssertEqual(
            proxied.absoluteString,
            "https://gh-proxy.com/https://github.com/mylxsw/typeflux/releases/download/v1/Typeflux.zip?download=1"
        )
    }

    func testReturnsNilForNonGitHubDownload() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/typeflux.zip"))

        XCTAssertNil(GitHubProxyDownloadURL.proxyURL(for: original))
    }
}
