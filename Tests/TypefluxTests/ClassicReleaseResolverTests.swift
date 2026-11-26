@testable import Typeflux
import XCTest

final class ClassicReleaseResolverTests: XCTestCase {
    private let base = URL(string: "https://api.example.com")!

    private func payload(version: String = "0.5.0", code: String = "OK", assets: String? = nil) -> Data {
        let assetJSON = assets ?? """
        [
          {"platform":"macos","architecture":"arm64","package_type":"full_dmg","channel":"global","file_name":"a.dmg","file_size":10,"sha256":"aa","download_url":"/d/macos/arm64/global?package_type=full_dmg"},
          {"platform":"macos","architecture":"arm64","package_type":"app_only_zip","channel":"cn","file_name":"cn.zip","file_size":20,"sha256":"bb","download_url":"/d/macos/arm64/cn?package_type=app_only_zip"},
          {"platform":"macos","architecture":"arm64","package_type":"app_only_zip","channel":"global","file_name":"g.zip","file_size":30,"sha256":"CC","download_url":"/d/macos/arm64/global?package_type=app_only_zip&product=classic"},
          {"platform":"macos","architecture":"x86_64","package_type":"app_only_zip","channel":"global","file_name":"i.zip","file_size":40,"sha256":"","download_url":"/d/macos/x86_64/global?package_type=app_only_zip"}
        ]
        """
        return Data("""
        {"code":"\(code)","message":"","data":{"version":"\(version)","title":"Classic","release_notes":"",
        "minimum_os":"13.0","source_url":"","published_at":"2026-11-26T00:00:00Z","assets":\(assetJSON)}}
        """.utf8)
    }

    func testPicksGlobalAppOnlyZipForArchitecture() throws {
        let package = try XCTUnwrap(ClassicReleaseResolver.package(from: payload(), apiBaseURL: base, architecture: "arm64"))
        XCTAssertEqual(package.version, "0.5.0")
        XCTAssertEqual(package.sha256, "cc")
        XCTAssertEqual(package.fileSize, 30)
        let components = try XCTUnwrap(URLComponents(url: package.downloadURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.example.com")
        XCTAssertEqual(components.path, "/d/macos/arm64/global")
        XCTAssertEqual(components.queryItems?.filter { $0.name == "product" }.map(\.value), ["classic"])
        XCTAssertEqual(components.queryItems?.first { $0.name == "package_type" }?.value, "app_only_zip")
    }

    func testIntelPackageGetsProductAndDropsEmptyChecksum() throws {
        let package = try XCTUnwrap(ClassicReleaseResolver.package(from: payload(), apiBaseURL: base, architecture: "x86_64"))
        XCTAssertNil(package.sha256)
        XCTAssertTrue(package.downloadURL.absoluteString.contains("product=classic"))
    }

    func testFallsBackToAnotherChannel() throws {
        let assets = """
        [{"platform":"macos","architecture":"arm64","package_type":"app_only_zip","channel":"cn","download_url":"https://cdn.example.com/c.zip"}]
        """
        let package = try XCTUnwrap(ClassicReleaseResolver.package(from: payload(assets: assets), apiBaseURL: base, architecture: "arm64"))
        XCTAssertEqual(package.downloadURL.absoluteString, "https://cdn.example.com/c.zip")
    }

    func testNoAssetForArchitectureMeansUnavailable() {
        let assets = """
        [{"platform":"macos","architecture":"x86_64","package_type":"full_dmg","channel":"global","download_url":"/d/x"}]
        """
        XCTAssertNil(ClassicReleaseResolver.package(from: payload(assets: assets), apiBaseURL: base, architecture: "arm64"))
        XCTAssertNil(ClassicReleaseResolver.package(from: payload(assets: "null"), apiBaseURL: base, architecture: "arm64"))
    }

    func testErrorEnvelopeMeansUnavailable() {
        let data = Data(#"{"code":"RELEASE_NOT_FOUND","message":"no release"}"#.utf8)
        XCTAssertNil(ClassicReleaseResolver.package(from: data, apiBaseURL: base, architecture: "arm64"))
        XCTAssertNil(ClassicReleaseResolver.package(from: Data("not json".utf8), apiBaseURL: base, architecture: "arm64"))
        XCTAssertNil(ClassicReleaseResolver.package(from: payload(code: "INTERNAL"), apiBaseURL: base, architecture: "arm64"))
    }

    func testTypefluxReleaseIsNeverOfferedAsClassic() {
        // A server that ignores product=classic answers with the latest Typeflux.
        XCTAssertNil(ClassicReleaseResolver.package(from: payload(version: "1.0.1"), apiBaseURL: base, architecture: "arm64"))
        XCTAssertNil(ClassicReleaseResolver.package(from: payload(version: ""), apiBaseURL: base, architecture: "arm64"))
        XCTAssertTrue(ClassicReleaseResolver.isClassicVersion("v0.5.0"))
        XCTAssertFalse(ClassicReleaseResolver.isClassicVersion("2.0"))
        XCTAssertFalse(ClassicReleaseResolver.isClassicVersion("beta"))
    }

    func testDownloadURLRejectsUnsupportedSchemes() {
        XCTAssertNil(ClassicReleaseResolver.downloadURL(for: "file:///tmp/a.zip", apiBaseURL: base))
        XCTAssertNil(ClassicReleaseResolver.downloadURL(for: "  ", apiBaseURL: base))
    }

    func testDownloadURLKeepsBasePathPrefix() throws {
        let prefixed = try XCTUnwrap(URL(string: "https://example.com/gateway/"))
        let url = try XCTUnwrap(ClassicReleaseResolver.downloadURL(for: "/d/macos/arm64/global", apiBaseURL: prefixed))
        XCTAssertEqual(url.absoluteString, "https://example.com/gateway/d/macos/arm64/global?product=classic")
    }

    func testAPIBaseURLStripsReleasePath() throws {
        let response = try XCTUnwrap(URL(string: "https://example.com/gateway/api/v1/app/releases/latest?product=classic"))
        XCTAssertEqual(ClassicReleaseResolver.apiBaseURL(fromResponseURL: response)?.absoluteString, "https://example.com/gateway")
    }

    func testAPIBaseURLWithoutReleasePathIsKept() throws {
        let response = try XCTUnwrap(URL(string: "https://example.com/other?x=1#frag"))
        XCTAssertEqual(ClassicReleaseResolver.apiBaseURL(fromResponseURL: response)?.absoluteString, "https://example.com/other")
    }

    func testServerArchitectureMapsIntel() {
        XCTAssertEqual(ClassicReleaseResolver.serverArchitecture("amd64"), "x86_64")
        XCTAssertEqual(ClassicReleaseResolver.serverArchitecture("arm64"), "arm64")
    }
}

final class ClassicBundleVerifierTests: XCTestCase {
    private let current = ClassicSigningIdentity(bundleIdentifier: "ai.gulu.app.typeflux", teamIdentifier: "TEAM123",
                                                 leafCertificateSHA256: "leaf")

    func testMatchingBundleAndTeamIsAccepted() {
        let candidate = ClassicSigningIdentity(bundleIdentifier: "ai.gulu.app.typeflux", teamIdentifier: "TEAM123",
                                               leafCertificateSHA256: "other-leaf")
        XCTAssertNoThrow(try ClassicBundleVerifier.verify(candidate: candidate, current: current))
    }

    func testDifferentBundleIdentifierIsRejected() {
        let candidate = ClassicSigningIdentity(bundleIdentifier: "com.example.fake", teamIdentifier: "TEAM123",
                                               leafCertificateSHA256: "leaf")
        XCTAssertThrowsError(try ClassicBundleVerifier.verify(candidate: candidate, current: current)) {
            XCTAssertEqual($0 as? ClassicBundleVerificationError, .bundleIdentifierMismatch)
        }
        let missing = ClassicSigningIdentity(bundleIdentifier: nil, teamIdentifier: "TEAM123", leafCertificateSHA256: nil)
        XCTAssertThrowsError(try ClassicBundleVerifier.verify(candidate: missing, current: current))
    }

    func testDifferentTeamIsRejected() {
        for team in ["OTHER", nil] {
            let candidate = ClassicSigningIdentity(bundleIdentifier: "ai.gulu.app.typeflux", teamIdentifier: team,
                                                   leafCertificateSHA256: "leaf")
            XCTAssertThrowsError(try ClassicBundleVerifier.verify(candidate: candidate, current: current)) {
                XCTAssertEqual($0 as? ClassicBundleVerificationError, .teamIdentifierMismatch)
            }
        }
    }

    func testTeamlessBuildRequiresTheSameCertificate() {
        let dev = ClassicSigningIdentity(bundleIdentifier: "ai.gulu.app.typeflux", teamIdentifier: nil,
                                         leafCertificateSHA256: "dev-leaf")
        XCTAssertNoThrow(try ClassicBundleVerifier.verify(candidate: dev, current: dev))

        let otherCertificate = ClassicSigningIdentity(bundleIdentifier: "ai.gulu.app.typeflux", teamIdentifier: nil,
                                                      leafCertificateSHA256: "attacker")
        XCTAssertThrowsError(try ClassicBundleVerifier.verify(candidate: otherCertificate, current: dev))

        let adHoc = ClassicSigningIdentity(bundleIdentifier: "ai.gulu.app.typeflux", teamIdentifier: nil,
                                           leafCertificateSHA256: nil)
        XCTAssertThrowsError(try ClassicBundleVerifier.verify(candidate: adHoc, current: adHoc))

        let teamSigned = ClassicSigningIdentity(bundleIdentifier: "ai.gulu.app.typeflux", teamIdentifier: "TEAM123",
                                                leafCertificateSHA256: "dev-leaf")
        XCTAssertThrowsError(try ClassicBundleVerifier.verify(candidate: teamSigned, current: dev))
    }

    func testErrorsHaveDescriptions() {
        XCTAssertNotNil(ClassicBundleVerificationError.bundleIdentifierMismatch.errorDescription)
        XCTAssertNotNil(ClassicBundleVerificationError.signatureUnreadable.errorDescription)
    }

    func testSHA256OfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("classic-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try ClassicBundleVerifier.sha256(ofFileAt: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testReadsIdentityOfASignedApp() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator.path))
        let identity = try ClassicBundleVerifier.identity(ofAppAt: calculator)
        XCTAssertEqual(identity.bundleIdentifier, "com.apple.calculator")
        XCTAssertNotNil(identity.leafCertificateSHA256)
        XCTAssertEqual(identity.leafCertificateSHA256?.count, 64)
    }

    func testReadsCurrentProcessIdentityWhenSigned() {
        // The test runner may be ad-hoc signed; either outcome must be a clean result, not a crash.
        if let identity = try? ClassicBundleVerifier.currentIdentity() {
            XCTAssertEqual(identity.bundleIdentifier, Bundle.main.bundleIdentifier)
        }
    }

    func testMissingAppIsUnreadable() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).app")
        XCTAssertThrowsError(try ClassicBundleVerifier.identity(ofAppAt: missing)) {
            XCTAssertEqual($0 as? ClassicBundleVerificationError, .signatureUnreadable)
        }
    }

    func testUnsignedDirectoryIdentityIsUnreadableOrTeamless() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Unsigned-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        if let identity = try? ClassicBundleVerifier.identity(ofAppAt: app) {
            XCTAssertNil(identity.teamIdentifier)
            XCTAssertNil(identity.leafCertificateSHA256)
        }
    }
}
