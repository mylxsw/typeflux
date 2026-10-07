import Foundation

struct AskGeneratedImageReceipt: Codable {
    var generatedImages: [AskArtifactRef]
    var provider: String
    var model: String
    var notice: String
}

extension AskLocalTools {
    func setExecutionDeadline(_ deadline: Date?, conversationId: String) {
        executionDeadlines[conversationId] = deadline
    }

    var imageSettings: AskImageSettings? {
        settings.map { AskImageSettings(defaults: $0.defaults) }
    }

    var imageConfiguration: (AskImageConfiguration, String)? {
        if let imageConfigurationOverride {
            return imageConfigurationOverride()
        }
        guard let store = imageSettings, store.isReady else { return nil }
        let config = store.configuration
        return (config, store.key(for: config))
    }

    static var imageGenerationDefinition: AskToolDefinition {
        .init(name: "generate_image", description: """
        Generate an image from a text prompt using the user's configured image provider after approval.
        This is a paid external request, not image understanding. Use only when the user requests an image.
        Request one image. Optional layout: auto (provider defaults), square, landscape or portrait.
        Returned artifact references are device-only images shown in the conversation with preview/save actions.
        Never invent a download URL or claim to have visually inspected an image. Do not automatically repeat
        failed, cancelled or uncertain requests, because generation may already have been charged.
        """, parameters: AskTypedContent.json([
            "type": "object", "additionalProperties": false, "required": ["prompt"],
            "properties": [
                "prompt": ["type": "string", "description": "Describe one image, including any desired text."],
                "layout": ["type": "string", "enum": ["auto", "square", "landscape", "portrait"]]
            ]
        ]))
    }

    func imageGenerationBinding(_ args: [String: Any]) throws -> AskToolBinding {
        let input = try AskImageRequest(arguments: args)
        guard let (config, key) = imageConfiguration else { throw AskImageError.configuration }
        let request = try AskImageGenerationService.request(input, configuration: config, key: key)
        // Bind all effective parameters and credential changes without serializing the secret.
        var material = Data((request.url!.absoluteString + "\n" + key).utf8)
        material.append(request.httpBody ?? Data())
        return .init(target: .init(kind: "network_origin", id: request.url!.absoluteString,
                                   version: AskToolPolicy.digest(material), domain: request.url?.host),
                     toolVersion: "image-generation-v1",
                     summary: L("imagegen.approval", config.provider.title, config.model,
                                config.size.isEmpty ? L("imagegen.layout." + input.layout) : config.size))
    }

    func executeImageGeneration(_ call: AskToolCall, conversationId: String, binding: AskToolBinding,
                                authorize: () throws -> Void) async throws -> AskLocalToolOutput {
        let args = try Self.jsonArguments(call.function.arguments)
        var input = try AskImageRequest(arguments: args)
        input.deadline = executionDeadlines[conversationId]
        guard let scope = projectScopes[conversationId], let (configuration, key) = imageConfiguration,
              try imageGenerationBinding(args) == binding else { throw AskImageError.configuration }
        try authorize()
        let result = try await imageGenerator.generate(input, configuration: configuration, key: key)
        try Task.checkCancellation()
        try authorize()
        guard projectScopes[conversationId] == scope else { throw CancellationError() }
        try artifactStore.cleanupExpired()
        var refs: [AskArtifactRef] = []
        for (index, image) in result.images.enumerated() {
            let name = "generated-\(index + 1)." + image.fileExtension
            let metadata = AskTypedContent.json([
                "provider": configuration.provider.rawValue, "model": configuration.model,
                "prompt": input.prompt, "layout": input.layout, "size": configuration.size,
                "width": image.width, "height": image.height,
                "request_id": result.requestID ?? "", "tool_call_id": call.id,
                "response_model": result.responseModel ?? "", "response_provider": result.responseProvider ?? "",
                "usage": result.usage.flatMap { try? JSONSerialization.jsonObject(with: $0.data) } ?? [:]
            ]).data
            try refs.append(artifactStore.publish(
                files: [name: image.data, "generation.json": metadata],
                entry: name,
                scope: scope
            ))
        }
        guard !refs.isEmpty else { throw AskImageError.noImage }
        let receipt = AskGeneratedImageReceipt(generatedImages: refs, provider: configuration.provider.rawValue,
                                               model: configuration.model,
                                               notice: """
                                               Generated images are saved on this Mac until the conversation is deleted.
                                               """)
        guard let text = try String(data: JSONEncoder().encode(receipt), encoding: .utf8) else {
            throw AskImageError.invalidResponse
        }
        return .init(
            content: text,
            outcome: .init(status: "ok", content: [AskTypedContent.json(["type": "text", "text": text])],
                           artifacts: refs, effectVerified: true)
        )
    }

    func deleteArtifacts(ownerId: String, conversationId: String) throws {
        try artifactStore.delete(ownerId: ownerId, conversationId: conversationId)
    }
}
