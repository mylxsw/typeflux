import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import Typeflux

func semanticTestImage(_ url: URL, red: Bool = true) throws {
    let context = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
        bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    context.setFillColor(CGColor(srgbRed: red ? 1 : 0, green: 0, blue: red ? 0 : 1, alpha: 1))
    context.fill(CGRect(x: 30, y: 30, width: 452, height: 452))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    try #require(CGImageDestinationFinalize(destination))
}

func semanticTestMovie(_ url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 64, AVVideoHeightKey: 64
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
    ])
    writer.add(input); try #require(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB,
                                        nil, &buffer) == kCVReturnSuccess)
    let frame = try #require(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    memset(CVPixelBufferGetBaseAddress(frame), 128, CVPixelBufferGetDataSize(frame))
    CVPixelBufferUnlockBaseAddress(frame, [])
    for index in 0 ..< 3 {
        for _ in 0 ..< 100 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 2)))
    }
    input.markAsFinished(); await writer.finishWriting(); try #require(writer.status == .completed)
}

@Suite("Isolated native media extraction", .serialized)
struct SemanticMediaExtractorTests {
    private func request(_ file: URL, root: URL) throws -> AskFileReadRequest {
        let scratch = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return .init(operation: .media, path: file.path, scope: semanticScope(root.path), scratch: scratch.path)
    }

    @Test func imagesAudioWindowsAndVideoFramesUsePrivateSnapshots() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png"), audio = root.appendingPathComponent("audio.wav")
        let movie = root.appendingPathComponent("movie.mov")
        try semanticTestImage(image)
        let samples = (0 ..< 31 * 16000).map { Float(sin(Double($0) * 0.12) * 0.2) }
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: audio) }
        try await semanticTestMovie(movie)
        let examples = [(image, [SemanticMediaInput.Kind.image]), (audio, [.audio, .audio]), (movie, [.image])]
        for (source, expected) in examples {
            let input = try request(source, root: root), reader = AskFileReader()
            var pieces: [SemanticMediaInput] = [], final: AskFileReadResponse?
            try reader.stream(input) { frame in
                if let media = frame.media { pieces.append(media) }
                if frame.more != true { final = frame }
                return true
            }
            #expect(final?.error == nil && final?.fileSize ?? 0 > 0)
            #expect(pieces.map(\.kind) == expected)
            #expect(pieces.allSatisfy { ($0.path as NSString).deletingLastPathComponent == input.scratch })
            for piece in pieces {
                #expect(FileManager.default.fileExists(atPath: piece.path))
                let attributes = try FileManager.default.attributesOfItem(atPath: piece.path)
                let permissions = attributes[.posixPermissions] as? Int
                #expect(permissions == 0o600)
            }
            if source == audio { #expect(pieces.map(\.time) == [0, 30]) }
            // The disposable child is killed by its owner and cannot flush coverage on exit.
            // Also verify the worker entry point directly, comparing its contract with real IPC.
            var directPieces: [SemanticMediaInput] = []
            let direct = try SemanticMediaExtractor.extract(request(source, root: root), mounts: .init(excluded: [])) {
                if let media = $0.media { directPieces.append(media) }
            }
            #expect(direct.error == final?.error && direct.fileSize == final?.fileSize)
            #expect(direct.modified == final?.modified)
            #expect(directPieces.map(\.kind) == pieces.map(\.kind))
            #expect(directPieces.map(\.time) == pieces.map(\.time))
        }
    }

    @Test func safePathsAndScratchPermissionsAreEnforcedBeforeDecoding() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        try semanticTestImage(file)
        func response(_ request: AskFileReadRequest, mounts: AskFileMounts = .init(excluded: [])) throws
            -> AskFileReadResponse {
            try SemanticMediaExtractor.extract(request, mounts: mounts, emit: { _ in })
        }
        #expect(try response(.init(operation: .media, path: file.path)).error == EACCES)
        var input = try request(file, root: root)
        #expect(try response(input, mounts: .init(excluded: [root.path])).skippedMounts == [root.path])
        input.scratch = root.path + "/missing"
        #expect(try response(input).error == EACCES)
        input = try request(file, root: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: input.scratch!)
        #expect(try response(input).error == EACCES)
        let link = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try response(request(link, root: root)).error != nil)
        let folder = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: root)
        #expect(try response(request(folder.appendingPathComponent("image.png"), root: root)).error != nil)
        #expect(try response(request(root.appendingPathComponent("absent.png"), root: root)).error != nil)
        #expect(try response(request(root.appendingPathComponent("notes.pdf"), root: root)).error == EACCES)
        try Data("invalid".utf8).write(to: file)
        #expect(try response(request(file, root: root)).error == EILSEQ)
        #expect(throws: (any Error).self) { try SemanticMediaExtractor.image(file, to: root) }
        #expect(throws: (any Error).self) { try SemanticMediaExtractor.wave(Data(), to: root) }
    }

    @Test func mediaMetadataDoesNotInheritTheDocumentSizeCap() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.mov")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SemanticFilePolicy.maximumBytes + 1)); try handle.close()
        let info = AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                                     scope: semanticScope(root.path), readText: false))
        #expect(info.error == nil && info.fileSize == Int64(SemanticFilePolicy.maximumBytes + 1))
        #expect(AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                                  scope: semanticScope(root.path))).error == EINVAL)
    }
}
