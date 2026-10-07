import AppKit
@testable import Typeflux
import XCTest

actor ImageTransportStub: AskImageTransport {
    var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) throws -> Data
    init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> Data) {
        self.handler = handler
    }

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        requests.append(request)
        let data = try handler(request, requests.count)
        guard data.count <= limit else { throw AskImageError.tooLarge }
        return data
    }
}

@MainActor
final class AskImageGenerationTests: XCTestCase {
    static func picture(_ type: NSBitmapImageRep.FileType = .png) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                                    bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }

    private func input(_ layout: String = "auto") throws -> AskImageRequest {
        try .init(arguments: ["prompt": "A small blue bird", "layout": layout])
    }

    func testLocalImageDataCoexistsWithPersistedConversationImage() throws {
        let bytes = try Self.picture()
        let local = try AskGeneratedImageData(data: bytes)
        let generated = AskImageGenerationResult(images: [local])
        XCTAssertEqual(generated.images.first?.data, bytes)
        XCTAssertEqual(generated.images.first?.mediaType, "image/png")

        let remote = AskGeneratedImage(assetId: "asset-id", url: "https://cdn.example/image.png")
        let message = AskMessage(id: "result", role: "tool", text: "Created", createdAt: Date(), generatedImage: remote)
        let restored = try AskCoding.decoder().decode(AskMessage.self, from: AskCoding.encoder().encode(message))
        XCTAssertEqual(restored.generatedImage, remote)
        XCTAssertEqual(restored.generatedImage?.safeURL?.absoluteString, remote.url)
        let outputs = AskRunOutputs(generatedImages: [remote])
        XCTAssertEqual(outputs, AskRunOutputs(generatedImages: [remote]))
        XCTAssertFalse(outputs.isEmpty)
    }

    func testGenerationAndDownloadShareRemainingTaskDeadline() async throws {
        var request = try input()
        request.deadline = Date().addingTimeInterval(10)
        let configured = try AskImageGenerationService.request(request, configuration: .preset(.google), key: "key")
        XCTAssertGreaterThan(configured.timeoutInterval, 0)
        XCTAssertLessThanOrEqual(configured.timeoutInterval, 10)
        let png = try Self.picture()
        let transport = ImageTransportStub { request, count in
            XCTAssertLessThanOrEqual(request.timeoutInterval, 10)
            if count == 1 {
                return Data(#"{"output":{"choices":[{"message":{"content":[{"image":"https://dashscope-result.oss-cn-beijing.aliyuncs.com/a.png"}]}}]}}"#
                    .utf8)
            }
            return png
        }
        _ = try await AskImageGenerationService(transport: transport).generate(
            request,
            configuration: .preset(.bailian),
            key: "key"
        )
        request.deadline = Date().addingTimeInterval(-1)
        do {
            _ = try await AskImageGenerationService(transport: transport).generate(
                request,
                configuration: .preset(.bailian),
                key: "key"
            )
            XCTFail()
        } catch { XCTAssertTrue(error is AskBudgetError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 2, "An expired run must not dispatch a paid request")
    }

    private func body(_ provider: AskImageProvider, layout: String = "auto", size: String = "",
                      quality: String = "") throws -> [String: Any] {
        var config = AskImageConfiguration.preset(provider)
        config.model = "brand-new/model-v99"
        config.size = size; config.quality = quality
        let request = try AskImageGenerationService.request(input(layout), configuration: config, key: "secret")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: provider == .google ? "x-goog-api-key" : "Authorization"),
                       provider == .google ? "secret" : "Bearer secret")
        XCTAssertEqual(request.timeoutInterval, 180)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "brand-new/model-v99", "Manual IDs must reach the provider unchanged")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("secret"))
        return body
    }

    func testManualModelsAndProviderSpecificRequests() throws {
        for provider in AskImageProvider.allCases {
            XCTAssertFalse(provider.title.isEmpty)
            XCTAssertFalse(provider.suggestedModels.isEmpty)
            let plain = try body(provider)
            XCTAssertNil(plain["size"])
            XCTAssertNil(plain["quality"])
        }
        let openai = try body(.openAI, layout: "landscape", quality: "high")
        XCTAssertEqual(openai["size"] as? String, "1536x1024")
        XCTAssertEqual(openai["quality"] as? String, "high")
        XCTAssertNil(openai["response_format"])
        let volc = try body(.volcengine, layout: "portrait")
        XCTAssertEqual(volc["size"] as? String, "1664x2496")
        XCTAssertEqual(volc["response_format"] as? String, "b64_json")
        XCTAssertNil(volc["quality"])
        let bailian = try body(.bailian, layout: "landscape")
        XCTAssertEqual((bailian["parameters"] as? [String: Any])?["size"] as? String, "1472*1104")
        XCTAssertNotNil((bailian["input"] as? [String: Any])?["messages"])
        let google = try body(.google, layout: "square", size: "2K")
        XCTAssertEqual((google["response_format"] as? [String: Any])?["aspect_ratio"] as? String, "1:1")
        XCTAssertEqual((google["response_format"] as? [String: Any])?["image_size"] as? String, "2K")
        XCTAssertEqual(google["store"] as? Bool, false)
        let router = try body(.openRouter, layout: "portrait", quality: "high")
        XCTAssertEqual(router["aspect_ratio"] as? String, "2:3")
        XCTAssertEqual((router["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool, false)
        for provider in [AskImageProvider.openAI, .volcengine, .bailian, .openRouter] {
            let explicit = try body(provider, layout: "portrait", size: "1536x1024")
            if provider == .bailian {
                XCTAssertEqual((explicit["parameters"] as? [String: Any])?["size"] as? String, "1536*1024")
            } else {
                XCTAssertEqual(explicit["size"] as? String, "1536x1024")
            }
        }
        var config = AskImageConfiguration.preset(.openRouter)
        config.routingProvider = "google-ai-studio"
        let request = try AskImageGenerationService.request(input(), configuration: config, key: "key")
        let value = try AskImageGenerationService.object(XCTUnwrap(request.httpBody))
        XCTAssertEqual((value["provider"] as? [String: Any])?["only"] as? [String], ["google-ai-studio"])
    }

    func testInvalidInputsAndConfigurationFailBeforeDispatch() throws {
        for args: [String: Any] in [[:], ["prompt": " "], ["prompt": "x", "layout": "4k"],
                                    ["prompt": "x", "layout": 1], ["prompt": "x", "url": "https://example.com"],
                                    ["prompt": String(repeating: "x", count: 16001)]] {
            XCTAssertThrowsError(try AskImageRequest(arguments: args))
        }
        XCTAssertNil(try input().aspectRatio)
        for base in [
            "",
            "http://example.com",
            "https://user:pass@example.com",
            "https://example.com?key=x",
            "https://example.com/#x"
        ] {
            var config = AskImageConfiguration(); config.baseURL = base
            XCTAssertThrowsError(try config.validate(key: "key"))
        }
        for key in ["", "  ", "a\nb", "a\rb"] {
            XCTAssertThrowsError(try AskImageConfiguration().validate(key: key))
        }
        var config = AskImageConfiguration(); config.model = ""
        XCTAssertThrowsError(try config.validate(key: "key"))
        XCTAssertNoThrow(try config.validate(key: "key", needsModel: false))
        config.model = "not-in-any-catalog-2099"
        XCTAssertNoThrow(try config.validate(key: "key"))
        config.quality = "bad\nvalue"
        XCTAssertThrowsError(try config.validate(key: "key"))
        for error in [AskImageError.configuration, .arguments, .invalidResponse, .noImage, .tooLarge,
                      .downloadDenied, .keychain, .discovery, .http(429)] {
            XCTAssertFalse(error.localizedDescription.hasPrefix("imagegen.error."))
        }
    }

    func testAllProvidersDecodeImagesAndPreserveOriginalBytes() async throws {
        let png = try Self.picture()
        for provider in AskImageProvider.allCases {
            let transport = ImageTransportStub { request, _ in
                if request.httpMethod == "GET" {
                    return png
                }
                let response: [String: Any] = switch provider {
                case .google:
                    ["status": "completed", "id": "request-id", "steps": [["type": "model_output", "content": [
                        ["type": "text", "text": "Here it is"], [
                            "type": "image",
                            "mime_type": "image/png",
                            "data": png.base64EncodedString()
                        ]
                    ]]]]
                case .bailian:
                    [
                        "request_id": "request-id",
                        "output": [
                            "choices": [
                                [
                                    "message": [
                                        "content": [
                                            [
                                                "image": "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/one.png?Expires=123"
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                default: ["data": [["b64_json": png.base64EncodedString()]], "usage": ["image_count": 1]]
                }
                return try JSONSerialization.data(withJSONObject: response)
            }
            let result = try await AskImageGenerationService(transport: transport).generate(
                input(),
                configuration: .preset(provider),
                key: "key"
            )
            XCTAssertEqual(result.images.count, 1)
            XCTAssertEqual(result.images.first?.data, png)
            XCTAssertEqual(result.images.first?.width, 8)
            XCTAssertEqual(result.images.first?.height, 6)
            XCTAssertEqual(result.images.first?.fileExtension, "png")
            let requests = await transport.requests
            XCTAssertEqual(requests.count, provider == .bailian ? 2 : 1)
            if provider == .bailian {
                XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(requests[1].value(forHTTPHeaderField: "x-goog-api-key"))
            }
        }
        let jpeg = try AskGeneratedImageData(data: Self.picture(.jpeg))
        XCTAssertEqual(jpeg.mediaType, "image/jpeg")
        XCTAssertEqual(jpeg.fileExtension, "jpg")
    }

    func testFailureNeverRetriesPaidGeneration() async throws {
        let fixtures: [[String: Any]] = [[:], ["error": ["message": "secret"]], ["data": [["b64_json": "broken"]]],
                                         ["data": [["url": "https://example.com/image.png"]]],
                                         ["data": [["b64_json": Data("not image".utf8).base64EncodedString()]]],
                                         ["data": Array(repeating: ["b64_json": ""], count: 9)]]
        for body in fixtures {
            let data = try JSONSerialization.data(withJSONObject: body)
            let transport = ImageTransportStub { _, _ in data }
            do {
                _ = try await AskImageGenerationService(transport: transport).generate(
                    input(),
                    configuration: .preset(.openAI),
                    key: "key"
                )
                XCTFail("Invalid responses must not be successful")
            } catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
        let transport = ImageTransportStub { _, _ in throw URLError(.timedOut) }
        do { _ = try await AskImageGenerationService(transport: transport).generate(
            input(),
            configuration: .preset(.openAI),
            key: "key"
        ); XCTFail() } catch {}
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertThrowsError(try AskGeneratedImageData(data: Data()))
        XCTAssertThrowsError(try AskGeneratedImageData(data: Data(
            repeating: 0,
            count: AskArtifactStore.maximumFileBytes + 1
        )))
        XCTAssertThrowsError(try AskImageGenerationService.object(Data("not JSON".utf8)))
        XCTAssertThrowsError(try AskImageGenerationService.sources(["status": "failed"], provider: .google))
        XCTAssertThrowsError(try AskImageGenerationService.sources(
            ["status": "completed", "outputs": [["type": "image"]]],
            provider: .google
        ))
        XCTAssertEqual(
            try AskImageGenerationService
                .sources(["status": "completed", "outputs": [["type": "image", "data": "a"]]], provider: .google).count,
            1
        )
    }

    func testDownloadRetriesOnlyTransientReadFailuresOnce() async throws {
        let response = Data(#"{"model":"actual-model","provider":"actual-provider","output":{"choices":[{"message":{"content":[{"image":"https://dashscope-result.oss-cn-beijing.aliyuncs.com/a.png"}]}}]}}"#
            .utf8)
        let png = try Self.picture()
        for failure in [AskImageError.http(503) as any Error, URLError(.networkConnectionLost)] {
            let transport = ImageTransportStub { request, count in
                if count == 1 {
                    return response
                }
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                if count == 2 {
                    throw failure
                }
                return png
            }
            let result = try await AskImageGenerationService(transport: transport).generate(
                input(),
                configuration: .preset(.bailian),
                key: "key"
            )
            XCTAssertEqual(result.images.first?.data, png)
            XCTAssertEqual(result.responseModel, "actual-model")
            XCTAssertEqual(result.responseProvider, "actual-provider")
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
            XCTAssertEqual(requests[1].url, requests[2].url)
        }
        for (failure, expectedCount) in [(AskImageError.http(403) as any Error, 2),
                                         (AskImageError.tooLarge, 2), (CancellationError(), 2),
                                         (URLError(.timedOut), 3)] {
            let transport = ImageTransportStub { _, count in
                if count == 1 {
                    return response
                }
                throw failure
            }
            do {
                _ = try await AskImageGenerationService(transport: transport).generate(
                    input(),
                    configuration: .preset(.bailian),
                    key: "key"
                )
                XCTFail()
            } catch {}
            let count = await transport.requests.count
            XCTAssertEqual(count, expectedCount)
        }
    }

    func testDownloadBoundary() throws {
        for raw in [
            "http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/a.png",
            "https://127.0.0.1/x",
            "https://example.com/a",
            "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com.evil.test/a",
            "https://user:secret@dashscope-result-bj.oss-cn-beijing.aliyuncs.com/a",
            "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com:444/a",
            "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/a#x"
        ] {
            XCTAssertThrowsError(try AskImageGenerationService.downloadURL(raw, provider: .bailian))
        }
        let valid = "https://dashscope-result-sh.oss-cn-shanghai.aliyuncs.com/a.png?Expires=1&Signature=test"
        XCTAssertEqual(try AskImageGenerationService.downloadURL(valid, provider: .bailian).absoluteString, valid)
        XCTAssertThrowsError(try AskImageGenerationService.downloadURL(valid, provider: .openAI))
    }

    func testDiscoveryIncludesNewModelsAndUsesPagination() async throws {
        for provider in [AskImageProvider.openAI, .openRouter, .google, .bailian] {
            let transport = ImageTransportStub { request, index in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.httpBody)
                let result: [String: Any]
                switch provider {
                case .google:
                    result = index == 1 ? ["models": [["name": "models/brand-new-model"]], "nextPageToken": "next"]
                        : ["models": [["name": "models/gemini-image"], ["name": "models/brand-new-model"]]]
                    if index == 2 {
                        XCTAssertTrue(request.url!.query!.contains("pageToken=next"))
                    }
                case .bailian:
                    result = ["output": [
                        "total": 101,
                        "models": [["model": index == 1 ? "qwen-image-new" : "new-unusual-name"]]
                    ]]
                    XCTAssertTrue(request.url!.query!.contains("capabilities=IG"))
                default:
                    result = ["data": [["id": "new-unusual-name"], ["id": "gpt-image-new"], ["id": "new-unusual-name"]]]
                    if provider == .openRouter {
                        XCTAssertEqual(request.url!.path, "/api/v1/images/models")
                    }
                }
                return try JSONSerialization.data(withJSONObject: result)
            }
            let found = try await AskImageModelDiscovery(transport: transport).models(
                configuration: .preset(provider),
                key: "key"
            )
            XCTAssertEqual(found.count, 2)
            XCTAssertTrue(AskImageModelDiscovery.imageLike(found[0]))
        }
        let never = ImageTransportStub { _, _ in
            XCTFail("Ark uses built-in suggestions without an API-key discovery endpoint"); return Data()
        }
        let names = try await AskImageModelDiscovery(transport: never).models(
            configuration: .preset(.volcengine),
            key: ""
        )
        XCTAssertEqual(names, AskImageProvider.volcengine.suggestedModels)
        for body: [String: Any] in [[:], ["models": [["name": "models/x"]], "nextPageToken": "repeated"]] {
            let data = try JSONSerialization.data(withJSONObject: body)
            let stub = ImageTransportStub { _, _ in data }
            do { _ = try await AskImageModelDiscovery(transport: stub).models(
                configuration: .preset(.google),
                key: "key"
            ); XCTFail() } catch { XCTAssertEqual(error as? AskImageError, .discovery) }
        }
    }
}
