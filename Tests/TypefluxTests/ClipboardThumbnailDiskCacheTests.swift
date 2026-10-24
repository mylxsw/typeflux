import AppKit
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

final class ClipboardThumbnailDiskCacheTests: XCTestCase {
    private func fixture() throws -> (URL, URL, ClipboardThumbnailDiskCache) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.png")
        // The cache only examines metadata. It must never parse original encoded bytes.
        try Data("original payload".utf8).write(to: source)
        return (root, source, ClipboardThumbnailDiskCache(directory: root.appendingPathComponent("cache")))
    }
    private func raster(width: Int = 56, height: Int = 40) -> AskFilePreviewPDF.Result {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return .init(images: [context.makeImage()!], numbers: [], pages: 0)
    }
    private func files(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"), includingPropertiesForKeys: nil)
    }

    func testRoundTripAcrossCacheInstancesKeepsPixelsAlphaAndOriginal() throws {
        let (root, source, cache) = try fixture()
        let key = try XCTUnwrap(cache.key(for: source, edge: 240)), original = try Data(contentsOf: source)
        XCTAssertNil(cache.read(key, edge: 240))
        let originalRaster = raster()
        cache.write(originalRaster, for: key, edge: 240)
        let next = ClipboardThumbnailDiskCache(directory: root.appendingPathComponent("cache"))
        let image = try XCTUnwrap(next.read(key, edge: 240)?.images.first)
        XCTAssertEqual(image.width, 56); XCTAssertEqual(image.height, 40)
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let expected = try XCTUnwrap(originalRaster.images[0].dataProvider?.data) as Data
        XCTAssertEqual(bytes, expected)
        XCTAssertTrue((127...128).contains(bytes[3]))
        XCTAssertEqual(try Data(contentsOf: source), original)
        let file = try XCTUnwrap(files(root).first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }

    func testShelfThumbnailSurvivesReopeningAndProviderUsesDiskWithoutDecodingOriginal() async throws {
        let (root, source, cache) = try fixture()
        let key = try XCTUnwrap(cache.key(for: source, edge: 480))
        let expected = raster(width: 480, height: 320)
        cache.write(expected, for: key, edge: 480)
        let listKey = try XCTUnwrap(cache.key(for: source, edge: 240))
        cache.write(raster(width: 240, height: 160), for: listKey, edge: 240)
        XCTAssertNotEqual(key.filename, listKey.filename)

        let reopened = ClipboardThumbnailDiskCache(directory: root.appendingPathComponent("cache"))
        let worker = MediaWorker(run: { _, _ in
            XCTFail("A cached shelf thumbnail must not decode the original again")
            throw MediaFailure.unavailable
        })
        let result = try await ClipboardThumbnailProvider.decode(source, edge: 480, worker: worker, diskCache: reopened)
        let image = try XCTUnwrap(result.images.first)
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 320)
        XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data,
                       try XCTUnwrap(expected.images[0].dataProvider?.data) as Data)
        XCTAssertEqual(reopened.read(listKey, edge: 240)?.images.first?.width, 240)
        XCTAssertNil(reopened.key(for: source, edge: 481))
    }

    func testSourceChangeOrDeletionInvalidatesBothReadsAndLateWrites() throws {
        let (root, source, cache) = try fixture(), result = raster()
        let key = try XCTUnwrap(cache.key(for: source, edge: 240))
        cache.write(result, for: key, edge: 240)
        try Data("different content".utf8).write(to: source, options: .atomic)
        XCTAssertNil(cache.read(key, edge: 240))
        let next = try XCTUnwrap(cache.key(for: source, edge: 240))
        XCTAssertNotEqual(key.filename, next.filename)
        XCTAssertNil(cache.read(next, edge: 240))
        cache.remove(for: source)
        cache.write(result, for: key, edge: 240)
        XCTAssertTrue(try files(root).isEmpty)
        try FileManager.default.removeItem(at: source)
        XCTAssertNil(cache.key(for: source, edge: 240))
        cache.write(result, for: next, edge: 240)
        XCTAssertTrue(try files(root).isEmpty)
    }

    func testMalformedOversizedAndSymlinkedCacheEntriesAreMisses() throws {
        let (root, source, cache) = try fixture()
        let key = try XCTUnwrap(cache.key(for: source, edge: 240))
        cache.write(raster(), for: key, edge: 240)
        let file = root.appendingPathComponent("cache").appendingPathComponent(key.filename)
        for data in [Data(), Data(repeating: 0, count: 12),
                     Data([84, 70, 67, 49, 255, 255, 255, 255, 0, 0, 0, 1]),
                     Data([84, 70, 67, 49, 0, 0, 0, 56, 0, 0, 0, 40]),
                     Data(repeating: 0, count: 600_000)] {
            try data.write(to: file)
            XCTAssertNil(cache.read(key, edge: 240))
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        XCTAssertNil(cache.read(key, edge: 240))
    }

    func testInvalidEdgesLargePreviewsAndInvalidRasterAreNeverStored() throws {
        let (root, source, cache) = try fixture()
        XCTAssertNil(cache.key(for: source, edge: 0))
        XCTAssertNil(cache.key(for: source, edge: 900))
        XCTAssertNil(cache.key(for: URL(string: "https://example.test/image")!, edge: 240))
        let key = try XCTUnwrap(cache.key(for: source, edge: 240))
        cache.write(raster(width: 241), for: key, edge: 240)
        cache.write(.init(images: [], numbers: [], pages: 0), for: key, edge: 240)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
        cache.write(raster(), for: key, edge: 240)
        XCTAssertNil(cache.read(key, edge: 32))
        XCTAssertNil(cache.read(key, edge: 900))
    }

    func testEvictsOldestForCountAndByteLimitsAndExpiresOldFiles() throws {
        let (root, source, _) = try fixture()
        let directory = root.appendingPathComponent("cache")
        let cache = ClipboardThumbnailDiskCache(directory: directory, byteLimit: 20_000, itemLimit: 2)
        for (index, edge) in [80, 120, 240].enumerated() {
            let key = try XCTUnwrap(cache.key(for: source, edge: edge))
            cache.write(raster(), for: key, edge: edge)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index - 3))],
                ofItemAtPath: directory.appendingPathComponent(key.filename).path)
        }
        XCTAssertEqual(try files(root).count, 2)
        XCTAssertNil(cache.read(try XCTUnwrap(cache.key(for: source, edge: 80)), edge: 80))
        let tiny = ClipboardThumbnailDiskCache(directory: directory, byteLimit: 9_000)
        let key = try XCTUnwrap(tiny.key(for: source, edge: 300))
        tiny.write(raster(), for: key, edge: 300)
        XCTAssertEqual(try files(root).count, 1)
        XCTAssertNotNil(tiny.read(key, edge: 300))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)],
            ofItemAtPath: directory.appendingPathComponent(key.filename).path)
        XCTAssertNil(tiny.read(key, edge: 300))
        let next = try XCTUnwrap(tiny.key(for: source, edge: 320))
        tiny.write(raster(), for: next, edge: 320)
        XCTAssertEqual(try files(root).map(\.lastPathComponent), [next.filename])
    }

    func testUnwritableCacheAndTooSmallBudgetDoNotChangeOriginal() throws {
        let (root, source, _) = try fixture(), original = try Data(contentsOf: source)
        for directory in [source, root.appendingPathComponent("small")] {
            let cache = ClipboardThumbnailDiskCache(directory: directory, byteLimit: directory == source ? 20_000 : 1)
            let key = try XCTUnwrap(cache.key(for: source, edge: 240))
            cache.write(raster(), for: key, edge: 240)
            XCTAssertNil(cache.read(key, edge: 240))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testStoreSchedulesPreparationAfterSavingAndDeletionRemovesOnlyItsThumbnails() throws {
        let (root, other, cache) = try fixture()
        let prepared = PreparedItems()
        let store = SQLiteClipboardHistoryStore(baseDir: root,
            thumbnailPreparation: { prepared.add($0) }, thumbnailCache: cache)
        let data = Data("captured bytes".utf8)
        let item = try XCTUnwrap(store.record(.image(png: data, pixelWidth: 56, pixelHeight: 40), source: nil, at: Date()))
        let source = URL(fileURLWithPath: try XCTUnwrap(item.imagePath))
        XCTAssertEqual(prepared.items.map(\.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: source), data)
        cache.write(raster(), for: try XCTUnwrap(cache.key(for: source, edge: 240)), edge: 240)
        let otherKey = try XCTUnwrap(cache.key(for: other, edge: 240))
        cache.write(raster(), for: otherKey, edge: 240)
        store.delete(id: item.id)
        XCTAssertEqual(try files(root).map(\.lastPathComponent), [otherKey.filename])
        XCTAssertNotNil(cache.read(otherKey, edge: 240))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let external = try XCTUnwrap(store.record(.files([other]), source: nil, at: Date()))
        store.delete(id: external.id)
        XCTAssertTrue(try files(root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}

private final class PreparedItems: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClipboardItem] = []
    var items: [ClipboardItem] { lock.withLock { values } }
    func add(_ item: ClipboardItem) { lock.withLock { values.append(item) } }
}
