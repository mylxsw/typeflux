import AppKit
import SwiftUI
@testable import Typeflux
import TypefluxChat
import XCTest

@MainActor
final class ModelIconTests: XCTestCase {
    func testModelFamilyPrecedesProviderAndImagesAreCached() throws {
        let provider = RegisteredProvider(id: "router", name: "OpenRouter", remote: .openRouter)
        let icon = ModelIcon(model: .init(id: "claude-sonnet-4", name: "Claude Sonnet"), provider: provider)
        XCTAssertEqual(icon.descriptor.resourceKey, "claude")
        for dark in [false, true] {
            let first = try XCTUnwrap(ModelIcon.image(for: icon.descriptor, dark: dark))
            XCTAssertGreaterThan(first.size.width, 0)
            XCTAssertTrue(ModelIcon.image(for: icon.descriptor, dark: dark) === first)
        }
        let unknown = ModelIcon(model: .init(id: "unknown", name: "Private model"),
                                provider: .init(id: "local", name: "Private", remote: .custom))
        XCTAssertEqual(unknown.descriptor, .provider)
        XCTAssertNil(ModelIcon.image(for: .generic, dark: false))
        XCTAssertNil(ModelIcon.image(for: .asset("missing", monochrome: true), dark: true))
    }

    func testEveryBundledIconDecodesInAppKit() throws {
        let first = try XCTUnwrap(ModelIconResolver.resolve(modelID: "claude").resourceURL(dark: false))
        let urls = try FileManager.default.contentsOfDirectory(at: first.deletingLastPathComponent(),
                                                               includingPropertiesForKeys: nil)
        let images = urls.filter { $0.pathExtension == "png" }
        XCTAssertEqual(images.count, 172)
        for url in images {
            let image = try XCTUnwrap(NSImage(contentsOf: url), url.lastPathComponent)
            XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil), url.lastPathComponent)
        }
    }

    func testModelRowsRenderInBothThemesWithFallbacksAndLongNames() throws {
        let models: [RegisteredModel] = [
            .init(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
            .init(id: "gpt-5", name: "GPT 5"),
            .init(id: "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B", name: "DeepSeek R1 Distill Qwen 32B"),
            .init(id: "qwen3:8b", name: "Qwen 3 · 8B"),
            .init(id: "kimi-k2", name: "Kimi K2"),
            .init(id: "glm-4.6", name: "GLM 4.6"),
            .init(id: "opaque", name: "Private deployment with a very long model name"),
            .init(id: "default", name: "Auto")
        ]
        let provider = RegisteredProvider(id: "typefluxCloud", name: "Typeflux Cloud", remote: .typefluxCloud)
        for dark in [false, true] {
            let content = VStack(alignment: .leading, spacing: 10) {
                Text("Model selection").font(.headline)
                ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                    AskPopoverRow(title: model.name, caption: model.id, selected: index == 0,
                                  enabled: index != 3, modelIcon: ModelIcon(model: model, provider: provider),
                                  action: {}, accessory: { EmptyView() })
                }
                HStack {
                    ModelIcon(model: models[0], provider: provider, size: 16)
                    Text("Claude Sonnet 4").font(.system(size: 13))
                }
            }
            .padding(16).frame(width: 400).background(StudioTheme.cardSurface)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertGreaterThan(image.size.height, 300)
            if let path = ProcessInfo.processInfo.environment["TYPEFLUX_CATALOG_CAPTURE_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(try NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("model-icons-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
