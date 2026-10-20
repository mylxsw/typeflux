import Foundation
import Testing
@testable import Typeflux

@Suite("Ask model failure recovery")
struct AskModelFailureTests {
    @Test(arguments: [
        ("MODEL_OUTPUT_LIMIT", "ask.failure.outputLimit"),
        ("MODEL_TIMEOUT", "ask.failure.timeout"),
        ("MODEL_STREAM_INTERRUPTED", "ask.failure.interrupted"),
        ("MODEL_EMPTY_RESPONSE", "ask.failure.empty"),
        ("MODEL_REQUEST_FAILED", "ask.failure.request"),
    ])
    func serverCodesSelectLocalizedRecovery(code: String, key: String) throws {
        var run = AskRun(id: "run", deviceId: "device", status: "failed", error: "Fallback", steps: 0,
                         updatedAt: Date(timeIntervalSince1970: 1_700_000_000), tools: [], pending: [])
        run.errorCode = code
        let data = try AskCoding.encoder().encode(run)
        #expect(String(decoding: data, as: UTF8.self).contains("error_code"))
        let decoded = try AskCoding.decoder().decode(AskRun.self, from: data)
        #expect(decoded.failureLocalizationKey == key)
        #expect(decoded.error == "Fallback")
    }

    @Test func olderAndUnknownFailureCodesRemainReadable() throws {
        var run = AskRun(id: "run", deviceId: "device", status: "failed", error: "Older server error", steps: 0,
                         updatedAt: Date(timeIntervalSince1970: 1_700_000_000), tools: [], pending: [])
        let data = try AskCoding.encoder().encode(run)
        #expect(try AskCoding.decoder().decode(AskRun.self, from: data).errorCode == nil)
        #expect(run.failureLocalizationKey == nil)
        run.errorCode = "FUTURE_CODE"
        #expect(run.failureLocalizationKey == nil)
        run.error = "The answer reached the output limit and was cut off; retry or ask to continue"
        #expect(run.failureLocalizationKey == "ask.failure.outputLimit")
    }
}
