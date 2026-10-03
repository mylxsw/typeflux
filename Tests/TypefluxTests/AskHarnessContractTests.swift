import CryptoKit
import Foundation
import XCTest
@testable import Typeflux

final class AskHarnessContractTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/harness/fixtures")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(name + ".json"))
    }

    func testFixtureManifest() throws {
        let manifest = try JSONDecoder().decode([String: String].self, from: fixture("manifest"))
        XCTAssertEqual(manifest.count, 7)
        for (name, expected) in manifest {
            let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected, name)
        }
    }

    func testContractRoundTripPreservesReferencesAndOpaqueContent() throws {
        let raw = try fixture("contract-v1")
        let value = try AskCoding.decoder().decode(AskHarnessContract.self, from: raw)
        let encoded = try AskCoding.encoder().encode(value)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: raw) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(value.outcome?.content?.count, 7)
        XCTAssertEqual(value.outcome?.safeStatus, .ok)
        XCTAssertEqual(value.outcome?.eventDispatched, true)
        XCTAssertEqual(value.outcome?.effectVerified, false)
        XCTAssertFalse(value.permits(.typedContent, peer: value))
    }

    func testNegotiationFixturesFailClosedUnlessExplicitlyEnabled() throws {
        struct Case: Decodable {
            var id: String
            var local: AskHarnessContract?
            var peer: AskHarnessContract?
            var enabled: [String]
            var requested: String
            var expected: Bool
        }
        let cases = try AskCoding.decoder().decode([Case].self, from: fixture("negotiation"))
        XCTAssertEqual(cases.count, 10)
        for value in cases {
            let capability = AskHarnessCapability(rawValue: value.requested)
            let enabled = Set(value.enabled.compactMap(AskHarnessCapability.init(rawValue:)))
            let permitted = capability.map { value.local?.permits($0, peer: value.peer, enabled: enabled) ?? false } ?? false
            XCTAssertEqual(permitted, value.expected, value.id)
        }
        for capability in AskHarnessCapability.allCases {
            let value = AskHarnessContract(version: 1, capabilities: [capability.rawValue])
            XCTAssertTrue(value.permits(capability, peer: value, enabled: [capability]))
        }
    }

    func testUnknownOutcomeIsReadableWithoutImplyingSuccess() {
        for status in AskExecutionStatus.allCases {
            XCTAssertEqual(AskExecutionOutcome(status: status.rawValue).safeStatus, status)
        }
        for raw in ["future_status", ""] {
            let value = AskExecutionOutcome(status: raw)
            XCTAssertEqual(value.safeStatus, .unknown)
            XCTAssertEqual(value.status, raw)
        }
    }

    func testLegacySnapshotsAndResultsNeedNoNewFields() throws {
        let old = try AskCoding.decoder().decode(AskConversation.self, from: fixture("legacy-conversation"))
        XCTAssertNil(old.harness)
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: AskCoding.encoder().encode(old)) as? [String: Any])
        XCTAssertNil(oldJSON["harness"])
        let result = try AskCoding.decoder().decode(AskToolResultRequest.self, from: fixture("legacy-result"))
        XCTAssertNil(result.harness)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: fixture("legacy-result")) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: AskCoding.encoder().encode(result)) as? NSDictionary)
        let current = try AskCoding.decoder().decode(AskConversation.self, from: fixture("current-conversation"))
        XCTAssertNotNil(current.harness)
        XCTAssertEqual(current.messages, old.messages)
        XCTAssertEqual(current.id, old.id)
        // This reader is the pre-P00 field subset. Unknown envelopes are ignored.
        struct LegacyConversation: Decodable {
            var id: String
            var revision: Int64
            var messages: [AskMessage]
        }
        let legacyReader = try AskCoding.decoder().decode(LegacyConversation.self, from: fixture("current-conversation"))
        XCTAssertEqual(legacyReader.messages, old.messages)
        XCTAssertEqual(legacyReader.revision, old.revision)
        struct LegacyResult: Decodable {
            var content: String
            var isError: Bool
        }
        let fallback = try AskCoding.decoder().decode(LegacyResult.self, from: fixture("current-result"))
        XCTAssertTrue(fallback.isError)
        XCTAssertTrue(fallback.content.contains("delivery is incomplete"))
        let rich = try AskCoding.decoder().decode(AskToolResultRequest.self, from: fixture("current-result"))
        XCTAssertNotNil(rich.harness)
        XCTAssertEqual(rich.content, fallback.content)
        XCTAssertEqual(rich.isError, fallback.isError)
    }

    func testThreeModeFixturesKeepRoutingAndCapabilitiesSeparate() throws {
        struct Mode: Decodable {
            var id: String
            var engine: String
            var inference: String
            var sendRequest: AskSendRequest
            var conversation: AskConversation
            var peer: AskHarnessContract?
            var expectedNewCapabilities: Bool
        }
        let modes = try AskCoding.decoder().decode([Mode].self, from: fixture("modes"))
        XCTAssertEqual(modes.count, 3)
        for mode in modes {
            XCTAssertEqual(mode.sendRequest.modelRef, mode.conversation.modelRef)
            XCTAssertEqual(mode.conversation.harness?.permits(.typedContent, peer: mode.peer), mode.expectedNewCapabilities)
            if mode.id == "cloud-cloud" {
                XCTAssertEqual(mode.sendRequest.modelRef, "cloud:fixture")
                XCTAssertEqual(mode.inference, "server_cloud")
            } else {
                XCTAssertEqual(mode.sendRequest.modelRef, "custom:fixture")
                XCTAssertEqual(mode.inference, "device_custom")
            }
            if mode.id == "local" {
                XCTAssertEqual(mode.engine, "local")
                XCTAssertNil(mode.peer)
            } else {
                XCTAssertEqual(mode.engine, "cloud")
            }
        }
    }
}
