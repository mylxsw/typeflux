import CoreImage
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskWorkflowDeveloperToolsTests {
    private func run(_ fixture: AskWorkflowFixture, _ id: String, keyword: String? = nil,
                     query: String = "", selection: String? = nil) async throws -> AskWorkflowTestResult {
        let item = try #require(AskWorkflowGallery.bundled.item(id))
        let path = await AskWorkflowPath.searchPath()
        let interpreter = try #require(item.runtime.interpreterName)
        #expect(AskWorkflowPath.resolve(interpreter, searchPath: path) != nil, "Install \(interpreter) to verify tools")
        let workflow = try fixture.store.installed(item) ?? fixture.store.add(item, builtIn: []).workflow
        return await AskWorkflowTester(home: fixture.home.path).run(
            workflow, input: AskWorkflowTestInput(query: query, selection: selection, keyword: keyword)
        )
    }

    @Test func `tools install and run using selected or typed text`() async throws {
        let fixture = try AskWorkflowFixture()
        let casing = try await run(fixture, "case", selection: "helloWorld")
        #expect(casing.succeeded, "\(casing.stderr)")
        let items = try #require(AskWorkflowItemList.parse(casing.stdout))
        #expect(items.items.count == 14 && items.items.contains { $0.arg == "hello_world" && $0.action == .copy })
        #expect(try await run(fixture, "case", query: "uppercase", selection: "Hello").stdout == "HELLO\n")
        let data = try await run(fixture, "data", query: "yaml json", selection: "name: Typeflux")
        #expect(data.succeeded && data.stdout.contains("\"name\": \"Typeflux\""), "\(data.stderr)")
        #expect(try await run(fixture, "data", query: "json toml {\"a\":null}").exitCode == 1)
        let markdown = try await run(fixture, "markup", keyword: "md2html", selection: "# Hello")
        #expect(markdown.succeeded && markdown.stdout == "<h1>Hello</h1>\n", "\(markdown.stderr)")
        let html = try await run(fixture, "markup", keyword: "html2md", query: "<h1>Hello</h1>")
        #expect(html.succeeded && html.stdout == "# Hello\n")
        let xml = try await run(
            fixture,
            "markup",
            keyword: "xmlfmt",
            query: "min",
            selection: "<root>\n  <a>1</a>\n</root>"
        )
        #expect(xml.succeeded && xml.stdout == "<root><a>1</a></root>\n")
        let escaped = try await run(fixture, "entities", query: "-e", selection: "<a>&你好</a>")
        #expect(escaped.succeeded && escaped.stdout == "&lt;a&gt;&amp;你好&lt;/a&gt;\n")
        let jwt = try await run(fixture, "jwt", selection: "eyJhbGciOiJub25lIn0.eyJzdWIiOiIxMjMifQ.")
        #expect(jwt.succeeded && jwt.stdout.contains("NOT verified") && jwt.stdout.contains("123"))
        let cron = try await run(fixture, "cron", query: "weekdays 09:00")
        #expect(cron.succeeded && AskWorkflowItemList.parse(cron.stdout)?.items.count == 2, "\(cron.stderr)")
        let quartz = try await run(fixture, "cron", query: "java 0 0 9 ? * MON-FRI")
        #expect(quartz.succeeded && quartz.stdout.contains("Quartz"))
        let subnet = try await run(fixture, "subnet", query: "192.168.1.42/24")
        #expect(subnet.succeeded && AskWorkflowItemList.parse(subnet.stdout)?.items
            .contains { $0.arg == "254" } == true)
        let emoji = try await run(fixture, "emoji", query: "火箭")
        #expect(emoji.succeeded && AskWorkflowItemList.parse(emoji.stdout)?.items.contains { $0.arg == "🚀" } == true)
        let masked = try await run(fixture, "obfuscate", query: "--keep-start 3 --keep-end 4", selection: "13812345678")
        #expect(masked.succeeded && masked.stdout == "138****5678\n")
        #expect(AskWorkflowGallery.bundled.item("emoji")?.manifest.run.mode == .onSubmit)
    }

    @Test func `qr result is displayed as an image and decodes to the original text`() async throws {
        let fixture = try AskWorkflowFixture()
        let result = try await run(fixture, "qr", query: "你好 Typeflux")
        #expect(result.succeeded, "\(result.stderr)")
        let folder = try #require(fixture.store.workflow("local.qr")?.folder)
        let resolved = AskWorkflowImage.resolve(result.stdout, folder: folder,
                                                cache: fixture.home.appendingPathComponent("qr-cache"),
                                                home: fixture.home.path)
        guard case let .success(image) = resolved
        else { Issue.record("Not a displayable QR image: \(resolved)"); return }
        #expect(image.width >= 200 && image.height == image.width)
        let ciImage = try #require(CIImage(contentsOf: image.url))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(codes == ["你好 Typeflux"])
        #expect(AskWorkflowGallery.bundled.item("qr")?.manifest.output.display == .image)
    }
}
