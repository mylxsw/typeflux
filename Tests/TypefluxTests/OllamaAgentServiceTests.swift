@testable import Typeflux
import XCTest

final class OllamaAgentServiceTests: XCTestCase {
    func testOllamaAgentServiceThrowsUnsupported() async {
        let service = OllamaAgentService()
        let request = LLMAgentRequest(
            systemPrompt: "sys",
            userPrompt: "usr",
            tools: [],
        )

        do {
            let _: String = try await service.runTool(request: request, decoding: String.self)
            XCTFail("Should throw unsupportedProvider")
        } catch let error as LLMAgentError {
            XCTAssertEqual(error, .unsupportedProvider)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
