import AppKit
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Typeflux

/// Builds images and files for the attachment tests.
enum AskAttachmentFixture {
    static func image(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: alpha ? 0.3 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ask-attach-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func decode(_ dataURL: String) -> CGImageSource {
        let base64 = String(dataURL.dropFirst("data:image/jpeg;base64,".count))
        return CGImageSourceCreateWithData(Data(base64Encoded: base64)! as CFData, nil)!
    }

    static func pixelSize(_ dataURL: String) -> (Int, Int) {
        let props = CGImageSourceCopyPropertiesAtIndex(decode(dataURL), 0, nil) as! [CFString: Any]
        return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
    }

    static func attachment(_ kind: AskAttachment.Kind, bytes: Int = 10, path: String? = nil) -> AskAttachment {
        switch kind {
        case .image: return AskAttachment(kind: .image, name: "a.jpg", image: String(repeating: "i", count: bytes))
        case .file: return AskAttachment(kind: .file, name: "a.txt", text: String(repeating: "t", count: bytes))
        case .folder: return AskAttachment(kind: .folder, name: "f", path: path ?? "/tmp/" + UUID().uuidString)
        }
    }
}

@Suite("Ask attachment loading")
struct AskAttachmentLoaderTests {
    @Test func largeImagesShrinkToTheLongEdgeAsJPEG() throws {
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 4000, height: 1000, alpha: true), type: .png)
        let attachment = try AskAttachmentLoader.image(data: png, name: "wide.png", byteSize: png.count)
        #expect(attachment.kind == .image)
        #expect(attachment.byteSize == png.count)
        let url = try #require(attachment.image)
        #expect(url.hasPrefix("data:image/jpeg;base64,"))
        let (width, height) = AskAttachmentFixture.pixelSize(url)
        #expect(width == AskAttachmentLimits.imageLongEdge)
        #expect(height == 512)
    }

    @Test func locationMetadataNeverLeavesTheMac() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N"]]
        let jpeg = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 40, height: 30), type: .jpeg, properties: gps)
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        #expect((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary] != nil)
        let attachment = try AskAttachmentLoader.image(data: jpeg, name: "trip.jpg", byteSize: jpeg.count)
        let props = CGImageSourceCopyPropertiesAtIndex(AskAttachmentFixture.decode(attachment.image!), 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func oversizedEncodingsShrinkUntilTheyFit() throws {
        let image = AskAttachmentFixture.image(width: 1200, height: 1200)
        let small = try #require(AskAttachmentLoader.jpegDataURL(image, limit: 4000))
        #expect(small.utf8.count <= 4000)
        #expect(AskAttachmentLoader.jpegDataURL(image, limit: 10) == nil)
    }

    @Test func unreadableImageDataIsRefused() {
        #expect(throws: AskAttachmentError.unreadable("x.png")) {
            try AskAttachmentLoader.image(data: Data("nope".utf8), name: "x.png", byteSize: 4)
        }
    }

    @Test func textDecodingCoversUTF8ChineseEncodingsAndRejectsBinary() {
        #expect(AskAttachmentLoader.decodeText(Data("héllo".utf8)) == "héllo")
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        #expect(AskAttachmentLoader.decodeText("你好，世界".data(using: gb)!) == "你好，世界")
        #expect(AskAttachmentLoader.decodeText(Data([0x50, 0x4B, 0x00, 0x01])) == nil)
    }

    @Test func filesBecomeTextImagesOrFoldersByType() throws {
        let dir = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = dir.appendingPathComponent("notes.md")
        try "# Plan".write(to: notes, atomically: true, encoding: .utf8)
        let text = try AskAttachmentLoader.file(notes)
        #expect(text == [AskAttachment(id: text[0].id, kind: .file, name: "notes.md", byteSize: 6, text: "# Plan")])

        let picture = dir.appendingPathComponent("shot.png")
        try AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 20, height: 10), type: .png).write(to: picture)
        #expect(try AskAttachmentLoader.file(picture).first?.kind == .image)

        let folder = try AskAttachmentLoader.file(dir)
        #expect(folder.first?.kind == .folder)
        #expect(folder.first?.path == dir.standardizedFileURL.path)

        let word = dir.appendingPathComponent("report.docx")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: word)
        #expect(throws: AskAttachmentError.unsupported("report.docx")) { try AskAttachmentLoader.file(word) }

        let binary = dir.appendingPathComponent("data.txt")
        try Data([0x00, 0x01, 0x02]).write(to: binary)
        #expect(throws: AskAttachmentError.unreadable("data.txt")) { try AskAttachmentLoader.file(binary) }
    }

    @Test func largeTextFilesAreRefusedAndLongTextIsTruncated() throws {
        let dir = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let huge = dir.appendingPathComponent("huge.log")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(AskAttachmentLimits.maximumTextFileBytes + 1))
        try handle.close()
        #expect(throws: AskAttachmentError.tooLarge("huge.log")) { try AskAttachmentLoader.file(huge) }

        let long = AskAttachmentLoader.textAttachment(String(repeating: "字", count: AskAttachmentLimits.maximumTextCharacters + 5),
                                                      name: "long.txt", byteSize: 1)
        #expect(long.text?.count == AskAttachmentLimits.maximumTextCharacters)
        #expect(long.truncated == true)
        #expect(AskAttachmentLoader.textAttachment("short", name: "s.txt", byteSize: 5).truncated == nil)
    }

    @Test @MainActor func pdfTextIsExtractedWithItsPageCount() throws {
        let dir = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = "Quarterly revenue grew"
        let url = dir.appendingPathComponent("report.pdf")
        try view.dataWithPDF(inside: view.bounds).write(to: url)
        let items = try AskAttachmentLoader.file(url)
        #expect(items.count == 1)
        #expect(items[0].pages == 1)
        #expect(items[0].text?.contains("Quarterly revenue grew") == true)
    }

    @Test @MainActor func scannedPDFPagesBecomeImages() throws {
        let dir = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let document = PDFDocument()
        for index in 0 ..< 2 {
            let page = PDFPage(image: NSImage(cgImage: AskAttachmentFixture.image(width: 300, height: 400), size: NSSize(width: 300, height: 400)))!
            document.insert(page, at: index)
        }
        let url = dir.appendingPathComponent("scan.pdf")
        #expect(document.write(to: url))
        let items = try AskAttachmentLoader.file(url)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.kind == .image && $0.image?.hasPrefix("data:image/jpeg;base64,") == true })
        #expect(items[1].name == L("ask.attach.pdfPage", "scan.pdf", 2))

        let broken = dir.appendingPathComponent("broken.pdf")
        try Data("not a pdf".utf8).write(to: broken)
        #expect(throws: AskAttachmentError.unreadable("broken.pdf")) { try AskAttachmentLoader.file(broken) }
    }

    @Test func batchesKeepLoadedItemsAndReportTheFirstFailure() throws {
        let dir = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("a.txt")
        try "a".write(to: good, atomically: true, encoding: .utf8)
        let batch = AskAttachmentBatch.load([.file(dir.appendingPathComponent("x.docx")), .file(good),
                                             .image(Data("bad".utf8), name: "clip")])
        #expect(batch.items.map(\.name) == ["a.txt"])
        #expect(batch.failure == .unsupported("x.docx"))
    }

    @Test func errorMessagesNameTheFile() {
        #expect(AskAttachmentError.unsupported("a.docx").message.contains("a.docx"))
        #expect(AskAttachmentError.tooLarge("b.log").message.contains("b.log"))
        #expect(AskAttachmentError.unreadable("c.txt").message.contains("c.txt"))
        for error in [AskAttachmentError.tooMany, .tooManyImages, .tooManyFolders, .payload] {
            #expect(!error.message.isEmpty)
        }
    }
}

@Suite("Ask attachment pasteboard", .exclusiveUIState)
@MainActor
struct AskAttachmentPasteboardTests {
    private func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("ask-attach-" + UUID().uuidString)) }

    @Test func filesWinOverTheirNamesAndIcons() {
        let board = pasteboard()
        board.clearContents()
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        board.writeObjects([url as NSURL])
        #expect(AskAttachmentSource.canRead(from: board))
        #expect(AskAttachmentSource.read(from: board) == [.file(url)])
        #expect(AskAttachmentSource.file(url).name == "report.pdf")
    }

    @Test func aCopiedImageAttachesButCopiedTextPastesAsText() {
        let board = pasteboard()
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 4, height: 4), type: .png)
        board.clearContents()
        board.setData(png, forType: .png)
        #expect(AskAttachmentSource.canRead(from: board))
        #expect(AskAttachmentSource.read(from: board) == [.image(png, name: L("ask.attach.pastedImage"))])

        // Notes and Word put a picture next to copied text; the text must win.
        board.clearContents()
        board.setString("Hello", forType: .string)
        board.setData(png, forType: .png)
        #expect(!AskAttachmentSource.canRead(from: board))
        #expect(AskAttachmentSource.read(from: board).isEmpty)
        // A drag is deliberate: the image wins over the address dragged with it.
        #expect(AskAttachmentSource.canRead(from: board, textWins: false))
        #expect(AskAttachmentSource.read(from: board, textWins: false).count == 1)
    }

    @Test func theEditorAttachesOnPasteAndLeavesTextAlone() {
        let editor = AskComposerTextView.Editor()
        editor.isEditable = true
        var received: [AskAttachmentSource] = []
        let board = pasteboard()
        board.clearContents()
        board.setData(AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 2, height: 2), type: .png), forType: .png)
        #expect(!editor.attach(from: board), "without a handler the text view keeps its behaviour")
        editor.onAttach = { received += $0 }
        #expect(editor.attach(from: board))
        #expect(received.count == 1)
        board.clearContents()
        board.setString("text", forType: .string)
        #expect(!editor.attach(from: board))
        #expect(!editor.attach(from: board, textWins: false), "plain text never attaches")
        editor.isEditable = false
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        #expect(!editor.attach(from: board))
        #expect(editor.acceptableDragTypes.contains(.fileURL))
        #expect(editor.acceptableDragTypes.contains(.png))
    }
}

@Suite("Ask attachment drafts")
struct AskAttachmentDraftTests {
    @Test func attachmentsAloneCanBeSentAndNameTheConversation() {
        var draft = AskDraft.followUp
        #expect(!draft.canSend)
        draft.append([AskAttachment(kind: .file, name: "Plan.md", text: "x")])
        #expect(draft.canSend)
        #expect(draft.title == "Plan.md")
        draft.text = "  Summarize  "
        #expect(draft.title == "Summarize")
        let request = draft.request(deviceId: "d", tools: [])
        #expect(request.attachments?.map(\.name) == ["Plan.md"])
        #expect(!request.sendsImage)
    }

    @Test func imagesCountTowardsVisionWithOrWithoutTheScreenshot() {
        var draft = AskDraft.followUp
        #expect(!draft.sendsImage)
        draft.append([AskAttachmentFixture.attachment(.image)])
        #expect(draft.sendsImage)
        #expect(draft.attachedImageCount == 1)
        #expect(draft.request(deviceId: "d", tools: []).sendsImage)
        let message = AskMessage(id: "m", role: "user", text: "", createdAt: Date(), attachments: draft.attachments)
        #expect(message.hasImage)
        #expect(!AskMessage(id: "n", role: "user", text: "", createdAt: Date()).hasImage)
        #expect(AskMessage(id: "o", role: "user", text: "", image: "x", createdAt: Date()).hasImage)
    }

    @Test func limitsRefuseTheOverflowAndKeepWhatFits() {
        var draft = AskDraft.followUp
        let files = (0 ... AskAttachmentLimits.maximumItems).map { _ in AskAttachmentFixture.attachment(.file) }
        #expect(draft.append(files) == .tooMany)
        #expect(draft.attachments?.count == AskAttachmentLimits.maximumItems)

        var withScreen = AskDraft(screenshot: "shot")
        let images = (0 ..< AskAttachmentLimits.maximumImages).map { _ in AskAttachmentFixture.attachment(.image) }
        #expect(withScreen.append(images) == .tooManyImages)
        #expect(withScreen.attachedImageCount == AskAttachmentLimits.maximumImages - 1)

        var folders = AskDraft.followUp
        let same = AskAttachmentFixture.attachment(.folder, path: "/tmp/same")
        #expect(folders.append([same, AskAttachmentFixture.attachment(.folder, path: "/tmp/same")]) == nil)
        #expect(folders.attachments?.count == 1, "the same folder twice is one grant")
        let more = (0 ..< AskAttachmentLimits.maximumFolders).map { _ in AskAttachmentFixture.attachment(.folder) }
        #expect(folders.append(more) == .tooManyFolders)

        var heavy = AskDraft.followUp
        let half = AskAttachmentLimits.maximumPayloadBytes / 2 + 1
        #expect(heavy.append([AskAttachmentFixture.attachment(.file, bytes: half), AskAttachmentFixture.attachment(.file, bytes: half)]) == .payload)
        #expect(heavy.attachments?.count == 1)
    }

    @Test func removingTheLastAttachmentClearsTheList() {
        var draft = AskDraft.followUp
        let item = AskAttachmentFixture.attachment(.file)
        draft.append([item])
        draft.removeAttachment(item.id)
        #expect(draft.attachments == nil)
    }

    @Test func attachmentsSurviveTheWireFormat() throws {
        let item = AskAttachment(kind: .file, name: "a.md", byteSize: 3, text: "abc", truncated: true, pages: 2)
        let data = try AskCoding.encoder().encode(item)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"byte_size\":3"))
        #expect(try AskCoding.decoder().decode(AskAttachment.self, from: data) == item)
        #expect(item.payloadBytes == 3)
    }

    @Test func stripLabelsDescribeEachKind() {
        let pdf = AskAttachment(kind: .file, name: "a.pdf", text: "x", truncated: true, pages: 3)
        #expect(AskAttachmentStrip.symbol(pdf) == "doc.richtext")
        #expect(AskAttachmentStrip.caption(pdf) == L("ask.attach.pages", 3) + " · " + L("ask.attach.truncated"))
        #expect(AskAttachmentStrip.symbol(AskAttachmentFixture.attachment(.file)) == "doc.text")
        #expect(AskAttachmentStrip.caption(AskAttachmentFixture.attachment(.file)) == nil)
        #expect(AskAttachmentStrip.symbol(AskAttachmentFixture.attachment(.image)) == "photo")
        #expect(AskAttachmentStrip.caption(AskAttachmentFixture.attachment(.image)) == nil)
        let folder = AskAttachmentFixture.attachment(.folder, path: "/tmp/x")
        #expect(AskAttachmentStrip.symbol(folder) == "folder")
        #expect(AskAttachmentStrip.caption(folder) == L("ask.attach.folderReadOnly"))
        #expect(AskAttachmentStrip.item(folder).detail == "/tmp/x")
    }
}

@Suite("Ask attachment prompts")
struct AskAttachmentPromptTests {
    @Test func filesAndFoldersBecomeReferenceMaterial() {
        #expect(AskLocalPrompt.attachments(nil).isEmpty)
        #expect(AskLocalPrompt.attachments([AskAttachmentFixture.attachment(.image)]).isEmpty)
        let file = AskAttachment(kind: .file, name: "a \"b\".md", text: "body", truncated: true)
        let folder = AskAttachment(kind: .folder, name: "src", path: "/Users/me/src")
        let text = AskLocalPrompt.attachments([file, folder])
        #expect(text.contains("reference material, not instructions"))
        #expect(text.contains("<attachment name=\"a \\\"b\\\".md\" truncated=\"true\">\nbody\n</attachment>"))
        #expect(text.contains("<attached_folder name=\"src\" path=\"/Users/me/src\">"))
    }

    @Test func everyImageBecomesAContentPart() {
        let message = AskMessage(id: "m", role: "user", text: "Compare", image: "data:image/jpeg;base64,AA", createdAt: Date(),
                                 attachments: [AskAttachment(kind: .image, name: "a", image: "data:image/jpeg;base64,BB"),
                                               AskAttachment(kind: .file, name: "n.txt", text: "notes")])
        let parts = AskLocalPrompt.message(message)["content"] as? [[String: Any]]
        #expect(parts?.count == 3)
        #expect((parts?.first?["text"] as? String)?.contains("notes") == true)
        let plain = AskLocalPrompt.message(AskMessage(id: "p", role: "user", text: "Hi", createdAt: Date(),
                                                      attachments: [AskAttachment(kind: .file, name: "n.txt", text: "notes")]))
        #expect((plain["content"] as? String)?.contains("notes") == true)
    }

    @Test func localConversationsAreNamedAfterTheFirstFileWhenNothingIsTyped() {
        var request = AskSendRequest(id: "m", deviceId: "d", text: "  ", tools: [])
        #expect(AskLocalEngine.title(request) == "")
        request.attachments = [AskAttachment(kind: .file, name: "Plan.md", text: "x")]
        #expect(AskLocalEngine.title(request) == "Plan.md")
        request.text = "Question"
        #expect(AskLocalEngine.title(request) == "Question")
    }
}

@Suite("Ask folder grants", .exclusiveUIState)
@MainActor
struct AskFolderGrantTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "ask-grants-" + UUID().uuidString)! }

    @Test func grantsAreKeptPerConversationAndSurviveAReload() {
        let store = defaults()
        let grants = AskFolderGrants(defaults: store)
        grants.grant(["/a", "", "/a"], to: "ABC")
        grants.grant(["/b"], to: "abc")
        grants.grant([], to: "other")
        #expect(grants.folders(for: "abc") == ["/a", "/b"])
        #expect(AskFolderGrants(defaults: store).folders(for: "ABC") == ["/a", "/b"])
        #expect(grants.folders(for: "other").isEmpty)
        grants.revoke("abc")
        #expect(grants.folders(for: "abc").isEmpty)
    }

    @Test func theOldestConversationsDropOff() {
        let grants = AskFolderGrants(defaults: defaults())
        for index in 0 ... AskFolderGrants.maximumConversations { grants.grant(["/f"], to: "c\(index)") }
        #expect(grants.folders(for: "c0").isEmpty)
        #expect(grants.folders(for: "c\(AskFolderGrants.maximumConversations)") == ["/f"])
    }

    @Test func theFilesToolReadsGrantedFoldersOnlyInTheirConversation() async throws {
        let dir = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(defaults: defaults())
        settings.askFileAccessFolders = ["/settings"]
        let tools = AskLocalTools(registry: MCPRegistry(), settings: settings, folderGrants: AskFolderGrants(defaults: defaults()))
        tools.grantFolders([dir.path, "/settings"], conversationId: "c1")
        #expect(tools.fileTools(conversationId: "c1").roots == ["/settings", dir.path])
        #expect(tools.fileTools(conversationId: "c2").roots == ["/settings"])
        #expect(tools.fileTools(conversationId: nil).roots == ["/settings"])
        let definition = await tools.definitions(conversationId: "c1").first { $0.name == "files" }
        #expect(definition?.description.contains(dir.path) == true)
    }
}

@Suite("Ask attachment composer model", .exclusiveUIState)
@MainActor
struct AskAttachmentModelTests {
    @Test func loadedAttachmentsJoinTheDraftOnScreen() async throws {
        let f = try AskTestFixture()
        let item = AskAttachment(kind: .file, name: "a.txt", text: "x")
        f.model.addAttachments([.file(URL(fileURLWithPath: "/tmp/a.txt"))], launcher: false) { _ in
            AskAttachmentBatch(items: [item], failure: .unsupported("b.docx"))
        }
        #expect(f.model.isLoadingAttachments(launcher: false))
        #expect(!f.model.canSend)
        try await f.wait { !f.model.isLoadingAttachments(launcher: false) }
        #expect(f.model.draft.attachments == [item])
        #expect(f.model.attachmentNotice(launcher: false) == AskAttachmentError.unsupported("b.docx").message)
        f.model.dismissAttachmentNotice(launcher: false)
        #expect(f.model.attachmentNotice == nil)
        f.model.removeAttachment(item.id, launcher: false)
        #expect(f.model.draft.attachments == nil)
        f.model.addAttachments([], launcher: false)
        #expect(!f.model.isLoadingAttachments(launcher: false))
    }

    @Test func theLauncherKeepsItsOwnAttachmentsAndNotice() async throws {
        let f = try AskTestFixture()
        let item = AskAttachment(kind: .file, name: "l.txt", text: "x")
        f.model.addAttachments([.file(URL(fileURLWithPath: "/tmp/l.txt"))], launcher: true) { _ in
            AskAttachmentBatch(items: [item, item], failure: nil)
        }
        try await f.wait { !f.model.isLoadingAttachments(launcher: true) }
        #expect(f.model.launcherDraft.attachments?.count == 2)
        #expect(f.model.draft.attachments == nil)
        f.model.applyAttachments(AskAttachmentBatch(items: (0 ..< 12).map { _ in item }), launcher: true)
        #expect(f.model.launcherAttachmentNotice == AskAttachmentError.tooMany.message)
        f.model.removeAttachment(item.id, launcher: true)
        #expect(f.model.launcherAttachmentNotice == nil)
    }

    @Test func attachmentsForADraftTheUserLeftAreDropped() async throws {
        let f = try AskTestFixture()
        await f.api.seed(.init(id: "a", title: "A", revision: 1, updatedAt: Date(), messages: []))
        f.model.addAttachments([.file(URL(fileURLWithPath: "/tmp/a.txt"))], launcher: false) { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return AskAttachmentBatch(items: [AskAttachment(kind: .file, name: "late.txt", text: "x")])
        }
        await f.model.select("a")
        try await f.wait { f.model.attachmentLoads.isEmpty }
        #expect(f.model.draft.attachments == nil)
    }

    @Test func sendingCarriesAttachmentsAndGrantsFolders() async throws {
        let f = try AskTestFixture()
        f.model.draft.append([AskAttachment(kind: .file, name: "notes.md", text: "Notes"),
                              AskAttachment(kind: .folder, name: "src", path: "/Users/me/src")])
        #expect(f.model.canSend)
        f.model.submitDraft()
        try await f.wait { !(f.model.selected?.messages.isEmpty ?? true) }
        let id = try #require(f.model.selectedId)
        #expect(f.model.selected?.title == "notes.md")
        #expect(f.model.selected?.messages.first?.attachments?.count == 2)
        #expect(f.tools.grantedFolders[id] == ["/Users/me/src"])
        try await f.wait { !f.model.isBusy }
        #expect(await f.api.sends.last?.attachments?.map(\.name) == ["notes.md", "src"])
        #expect(f.model.draft.attachments == nil)
    }

    @Test func oversizedAttachmentsAreNotSent() async throws {
        let f = try AskTestFixture()
        let half = AskAttachmentLimits.maximumPayloadBytes / 2 + 1
        f.model.draft.attachments = [AskAttachmentFixture.attachment(.file, bytes: half), AskAttachmentFixture.attachment(.file, bytes: half)]
        f.model.submitDraft()
        #expect(f.model.error == L("ask.input.tooLarge"))
        #expect(await f.api.sends.isEmpty)
    }

    @Test func imagesOnAModelThatCannotReadThemExplainWhy() throws {
        let f = try AskTestFixture()
        f.model.applyAttachments(AskAttachmentBatch(items: [AskAttachmentFixture.attachment(.image)]), launcher: false)
        let capability = f.model.screenshotCapability(launcher: false)
        if capability == .supported {
            #expect(f.model.attachmentNotice == nil)
        } else {
            #expect(f.model.attachmentNotice == capability.hint)
        }
        #expect(f.model.requiresVision(launcher: false))
    }
}
