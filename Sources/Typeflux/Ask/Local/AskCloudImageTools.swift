import Foundation
import TypefluxChat

struct AskCloudImageCatalog: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        var alias: String
        var generate: Bool
        var edit: Bool
        var aspectRatios: [String]? = nil
        var resolutions: [String]? = nil
    }
    var models: [Model]
    var defaultGenerateModel: String
    var defaultEditModel: String

    var definitions: [AskToolDefinition] {
        var result: [AskToolDefinition] = []
        if models.contains(where: { $0.alias == defaultGenerateModel && $0.generate }) {
            result.append(definition(edit: false))
        }
        if models.contains(where: { $0.alias == defaultEditModel && $0.edit }) {
            result.append(definition(edit: true))
        }
        return result
    }

    private func definition(edit: Bool) -> AskToolDefinition {
        let supported = models.filter { edit ? $0.edit : $0.generate }
        var properties: [String: Any] = [
            "prompt": ["type": "string"],
            "model": ["type": "string", "enum": supported.map(\.alias), "description": "Omit to use the configured default."],
            "aspect_ratio": ["type": "string", "description": "Omit unless the user requests a particular aspect ratio."],
            "resolution": ["type": "string", "description": "Omit unless the user requests a particular resolution."]
        ]
        for (name, values) in [("aspect_ratio", supported.flatMap { $0.aspectRatios ?? [] }),
                               ("resolution", supported.flatMap { $0.resolutions ?? [] })] where !values.isEmpty {
            properties[name] = ["type": "string", "enum": Array(Set(values)).sorted(),
                                "description": "Optional; omit to use the cloud default."]
        }
        if edit {
            properties["image_refs"] = ["type": "array", "items": ["type": "string"],
                "description": "asset_id from an earlier generated image, or a user image attachment ID."]
        }
        return .init(name: edit ? "image_edit" : "image_generate", description: """
        \(edit ? "Edit reference images" : "Generate an image") using Typeflux Cloud when the user asks for it.
        Produces one image at the published per-image Credit price. Omit model to use the cloud default.
        Results appear as image cards. Do not substitute scripts or SVG drawings for this tool.
        Never automatically repeat a failed, cancelled or uncertain image request.
        """, parameters: AskLocalWebTools.schema(properties, required: edit ? ["prompt", "image_refs"] : ["prompt"]))
    }
}

struct AskCloudImageRequest: Codable, Sendable {
    var operation: String
    var prompt: String
    var model: String?
    var aspectRatio: String?
    var resolution: String?
    var inputAssetIds: [String]
}

struct AskCloudImageJob: Decodable, Sendable {
    var id: String
    var state: String
    var imageUrl: String?
    var errorCode: String?
    var deadline: Date

    var output: AskBuiltinToolOutput? {
        if state == "succeeded", let imageUrl {
            let image = AskGeneratedImage(assetId: id, url: imageUrl)
            guard image.safeURL != nil else { return .init(text: "Image result URL is invalid. Do not generate again automatically.", isError: true) }
            return .init(text: "Image created. asset_id=\(id) URL=\(imageUrl)", isError: false, generatedImage: image)
        }
        if state == "failed" {
            return .init(text: "Image generation failed (\(errorCode ?? "unknown")); job_id=\(id). Do not retry automatically.", isError: true)
        }
        return nil
    }
}

protocol AskCloudImageTransporting: Sendable {
    func catalog(token: String) async throws -> AskCloudImageCatalog
    func upload(dataURL: String, token: String) async throws -> String
    func create(_ request: AskCloudImageRequest, key: String, token: String) async throws -> AskCloudImageJob
    func job(id: String, token: String) async throws -> AskCloudImageJob
}

struct AskCloudImageTransport: AskCloudImageTransporting {
    var executor = CloudRequestExecutor()

    func catalog(token: String) async throws -> AskCloudImageCatalog {
        try await request("/image-models", token: token)
    }

    func upload(dataURL: String, token: String) async throws -> String {
        struct Uploaded: Decodable { var id: String }
        let body = try JSONSerialization.data(withJSONObject: ["data_url": dataURL])
        let result: Uploaded = try await request("/image-assets", body: body, token: token)
        return result.id
    }

    func create(_ value: AskCloudImageRequest, key: String, token: String) async throws -> AskCloudImageJob {
        try await request("/image-jobs", body: AskCoding.encoder().encode(value), key: key, token: token)
    }

    func job(id: String, token: String) async throws -> AskCloudImageJob {
        guard UUID(uuidString: id) != nil else { throw ChatAPIError.invalidResponse }
        return try await request("/image-jobs/\(id)", token: token)
    }

    private func request<T: Decodable>(_ path: String, body: Data? = nil, key: String? = nil, token: String) async throws -> T {
        let path = "/api/v1" + path
        let (data, response) = try await executor.execute(apiPath: path) { base in
            var request = ChatRequest.make(baseURL: base, path: path, method: body == nil ? "GET" : "POST", body: body, token: token, timeout: 30)
            if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
            return request
        }
        return try ChatRequest.decode(data: data, statusCode: response.statusCode)
    }
}

extension AskDeviceBuiltinHost {
    func availableDefinitions() async -> [AskToolDefinition] {
        guard let catalog = try? await images.catalog(token: token()) else { return definitions() }
        return definitions() + catalog.definitions
    }

    func executeImage(_ input: AskBuiltinToolInput) async -> AskBuiltinToolOutput {
        struct Arguments: Decodable {
            var prompt: String
            var model: String?
            var aspectRatio: String?
            var resolution: String?
            var imageRefs: [String]?
        }
        var submitted: AskCloudImageJob?
        do {
            let args = try AskCoding.decoder().decode(Arguments.self, from: Data(input.call.function.arguments.utf8))
            var refs: [String] = []
            for ref in args.imageRefs ?? [] {
                var dataURL: String?
                for message in input.conversation.messages where message.role == "user" {
                    if message.id == ref { dataURL = message.image }
                    if let attachment = message.attachments?.first(where: { $0.id == ref && $0.kind == .image }) { dataURL = attachment.image }
                }
                if let dataURL { refs.append(try await images.upload(dataURL: dataURL, token: token())) }
                else { refs.append(ref) }
            }
            try Task.checkCancellation()
            let key = "device-image:" + AskToolPolicy.digest([input.conversation.id, input.conversation.run?.id ?? "", input.call.id].joined(separator: ":"))
            let request = AskCloudImageRequest(operation: input.call.function.name == "image_edit" ? "edit" : "generate",
                prompt: args.prompt, model: args.model, aspectRatio: args.aspectRatio, resolution: args.resolution, inputAssetIds: refs)
            var job = try await images.create(request, key: key, token: token())
            submitted = job
            while true {
                if let output = job.output { return output }
                try Task.checkCancellation()
                // The durable server job owns the generation deadline. A transient
                // polling error never repeats the paid POST or discards the job ID.
                guard Date() < job.deadline.addingTimeInterval(60) else {
                    return .init(text: "Image job \(job.id) is still awaiting confirmation. Do not generate again automatically.", isError: true)
                }
                try await imagePollWait()
                let credential = try await token()
                do { job = try await images.job(id: job.id, token: credential) }
                catch is CancellationError { throw CancellationError() }
                catch ChatAPIError.unauthorized { throw ChatAPIError.unauthorized }
                catch ChatAPIError.server(let code, let message) where code == "IMAGE_NOT_FOUND" {
                    throw ChatAPIError.server(code: code, message: message)
                }
                catch { continue }
            }
        } catch {
            let receipt = submitted.map { " job_id=\($0.id). The cloud job may still finish." } ?? " The request may already have reached the service."
            let reason: String
            switch error {
            case ChatAPIError.server(let code, let message): reason = code + (message.map { ": " + $0 } ?? "")
            case ChatAPIError.unauthorized: reason = "Cloud sign-in is no longer valid"
            case ChatAPIError.invalidResponse: reason = "The cloud response could not be decoded"
            default: reason = error.localizedDescription
            }
            return .init(text: "Image request did not complete: \(reason).\(receipt) Do not automatically submit another image request.", isError: true)
        }
    }
}
