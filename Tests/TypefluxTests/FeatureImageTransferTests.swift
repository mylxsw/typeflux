import CoreGraphics
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized)
struct FeatureImageTransferTests {
    @Test func imageTransferRoundTripsAndRetainsTheProducerFileUntilAcknowledgement() throws {
        let id = UUID()
        defer { FeatureImageTransfer.remove(id) }
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = try ScreenshotImageExporter.png(image, scale: 1)
        try FeatureImageTransfer.write(data, id: id)
        let decoded = try FeatureImageTransfer.read(id)
        #expect(decoded.width == 8 && decoded.height == 6)
        #expect(FileManager.default.fileExists(atPath: FeatureImageTransfer.directory(id).path))
        FeatureImageTransfer.remove(id)
        #expect(throws: (any Error).self) { try FeatureImageTransfer.read(id) }
    }

    @Test func invalidImagesAndSymlinkSourcesAreRejected() throws {
        let id = UUID()
        defer { FeatureImageTransfer.remove(id) }
        #expect(throws: FeatureRPC.Failure.invalidMessage) { try FeatureImageTransfer.write(Data(), id: id) }
        try FeatureImageTransfer.write(Data("not an image".utf8), id: id)
        #expect(throws: FeatureRPC.Failure.invalidMessage) { try FeatureImageTransfer.read(id) }
        let file = FeatureImageTransfer.directory(id).appendingPathComponent("image.png")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/etc/hosts")
        #expect(throws: FeatureRPC.Failure.unavailable) { try FeatureImageTransfer.read(id) }
    }
}


@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureImageDeliveryTests {
    @Test func acknowledgedDeliveryRemovesOnlyItsPrivateTransferDirectory() async throws {
        var transfer: UUID?
        let data = Data([1, 2, 3])
        let result = try await FeatureImageDelivery.deliver(data, send: { id in
            transfer = id
            let received = try Data(contentsOf: FeatureImageTransfer.directory(id).appendingPathComponent("image.png"))
            #expect(received == data)
        }, save: { _ in Issue.record("Acknowledged delivery must not create a fallback save"); return URL(fileURLWithPath: "/unused") })
        #expect(result == .delivered)
        let id = try #require(transfer)
        #expect(!FileManager.default.fileExists(atPath: FeatureImageTransfer.directory(id).path))
    }

    @Test func aStagingFailureStillSavesTheOriginalBytes() async throws {
        let data = Data([4, 5, 6]), destination = URL(fileURLWithPath: "/fixture/saved.png")
        let result = try await FeatureImageDelivery.deliver(data, write: { _, _ in throw FeatureRPC.Failure.unavailable }, send: { _ in
            Issue.record("An unstaged capture cannot be delivered")
        }, save: { original in #expect(original == data); return destination })
        #expect(result == .saved(destination))
    }

    @Test func aRejectedOrStaleHandoffSavesAndCleansTheTransfer() async throws {
        var transfer: UUID?
        let destination = URL(fileURLWithPath: "/fixture/saved.png"), data = Data([7])
        let result = try await FeatureImageDelivery.deliver(data, send: { id in transfer = id; throw FeatureRPC.Failure.cancelled },
            save: { original in #expect(original == data); return destination })
        #expect(result == .saved(destination))
        let id = try #require(transfer)
        #expect(!FileManager.default.fileExists(atPath: FeatureImageTransfer.directory(id).path))
    }
}
