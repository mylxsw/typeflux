import Foundation

protocol LLMService {
    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error>
    func complete(systemPrompt: String, userPrompt: String) async throws -> String
}
