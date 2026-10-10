import CoreGraphics
import Testing
@testable import Typeflux

@Suite("Screen capture geometry")
struct ScreenCaptureGeometryTests {
    @Test func nativeResolutionUsesBackingScale() {
        let size = ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 1512, height: 982), scale: 2,
                                                   resolution: .native)
        #expect(size == ScreenPixelSize(width: 3024, height: 1964))
        let belowOne = ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 800, height: 600), scale: 0,
                                                       resolution: .native)
        #expect(belowOne == ScreenPixelSize(width: 800, height: 600))
    }

    @Test func fittingScalesPointsDownToTheLongerSide() {
        let landscape = ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 3200, height: 1800), scale: 2,
                                                        resolution: .fitting(maxDimension: 1600))
        #expect(landscape == ScreenPixelSize(width: 1600, height: 900))
        let portrait = ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 1080, height: 1920), scale: 1,
                                                       resolution: .fitting(maxDimension: 1600))
        #expect(portrait == ScreenPixelSize(width: 900, height: 1600))
    }

    @Test func fittingNeverUpscalesAndKeepsAtLeastOnePixel() {
        let small = ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 1440, height: 900), scale: 2,
                                                    resolution: .fitting(maxDimension: 1600))
        #expect(small == ScreenPixelSize(width: 1440, height: 900))
        let sliver = ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 10000, height: 1), scale: 1,
                                                     resolution: .fitting(maxDimension: 100))
        #expect(sliver == ScreenPixelSize(width: 100, height: 1))
        let empty = ScreenCaptureGeometry.pixelSize(pointSize: .zero, scale: 1, resolution: .fitting(maxDimension: 100))
        #expect(empty == ScreenPixelSize(width: 1, height: 1))
    }

    @Test func backingScaleComesFromTheDisplayMode() {
        #expect(ScreenCaptureGeometry.backingScale(pixelWidth: 3024, pointWidth: 1512) == 2)
        #expect(ScreenCaptureGeometry.backingScale(pixelWidth: 1920, pointWidth: 1920) == 1)
        #expect(ScreenCaptureGeometry.backingScale(pixelWidth: 0, pointWidth: 1512) == 1)
        #expect(ScreenCaptureGeometry.backingScale(pixelWidth: 3024, pointWidth: 0) == 1)
        #expect(ScreenCaptureGeometry.backingScale(pixelWidth: 800, pointWidth: 1600) == 1)
    }

    @Test func flippingBetweenQuartzAndAppKitIsItsOwnInverse() {
        let quartz = CGRect(x: 100, y: 50, width: 300, height: 200)
        let appKit = ScreenCaptureGeometry.flipped(quartz, primaryDisplayHeight: 1000)
        #expect(appKit == CGRect(x: 100, y: 750, width: 300, height: 200))
        #expect(ScreenCaptureGeometry.flipped(appKit, primaryDisplayHeight: 1000) == quartz)
        // A display above the primary one has a negative Quartz y.
        let above = ScreenCaptureGeometry.flipped(CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                                                  primaryDisplayHeight: 1000)
        #expect(above == CGRect(x: 0, y: 1000, width: 1920, height: 1080))
        let point = ScreenCaptureGeometry.flipped(CGPoint(x: 5, y: 10), primaryDisplayHeight: 1000)
        #expect(point == CGPoint(x: 5, y: 990))
    }

    @Test func pixelRectMapsGlobalPointsIntoTheDisplayImage() throws {
        let frame = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let native = try #require(ScreenCaptureGeometry.pixelRect(
            for: CGRect(x: 1612, y: 100, width: 200, height: 50), displayFrame: frame,
            imageSize: ScreenPixelSize(width: 3840, height: 2160)
        ))
        #expect(native == CGRect(x: 200, y: 200, width: 400, height: 100))
        let downscaled = try #require(ScreenCaptureGeometry.pixelRect(
            for: CGRect(x: 1512, y: 0, width: 960, height: 540), displayFrame: frame,
            imageSize: ScreenPixelSize(width: 1600, height: 900)
        ))
        #expect(downscaled == CGRect(x: 0, y: 0, width: 800, height: 450))
    }

    @Test func pixelRectClipsToTheDisplayAndRoundsOutward() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let size = ScreenPixelSize(width: 200, height: 200)
        let clipped = try #require(ScreenCaptureGeometry.pixelRect(
            for: CGRect(x: -50, y: 80, width: 100, height: 100), displayFrame: frame, imageSize: size
        ))
        #expect(clipped == CGRect(x: 0, y: 160, width: 100, height: 40))
        let fractional = try #require(ScreenCaptureGeometry.pixelRect(
            for: CGRect(x: 10.3, y: 10.3, width: 5.1, height: 5.1), displayFrame: frame,
            imageSize: ScreenPixelSize(width: 100, height: 100)
        ))
        #expect(fractional == CGRect(x: 10, y: 10, width: 6, height: 6))
    }

    @Test func pixelRectIsNilOffTheDisplay() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let size = ScreenPixelSize(width: 100, height: 100)
        #expect(ScreenCaptureGeometry.pixelRect(for: CGRect(x: 200, y: 0, width: 10, height: 10),
                                                displayFrame: frame, imageSize: size) == nil)
        #expect(ScreenCaptureGeometry.pixelRect(for: CGRect(x: 100, y: 0, width: 10, height: 10),
                                                displayFrame: frame, imageSize: size) == nil)
        #expect(ScreenCaptureGeometry.pixelRect(for: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                displayFrame: .zero, imageSize: size) == nil)
    }

    @Test func resizingRedrawsOnlyWhenTheSizeDiffers() throws {
        let image = ScreenCaptureTestSupport.image(width: 40, height: 20)
        let same = try #require(ScreenCaptureGeometry.resized(image, to: ScreenPixelSize(width: 40, height: 20)))
        #expect(same === image)
        let smaller = try #require(ScreenCaptureGeometry.resized(image, to: ScreenPixelSize(width: 10, height: 5)))
        #expect(smaller.width == 10 && smaller.height == 5)
        #expect(ScreenCaptureGeometry.resized(image, to: ScreenPixelSize(width: 0, height: 5)) == nil)
    }

    @Test func resizingConvertsNonRGBImagesToRGB() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let gray = try #require(context.makeImage())
        let resized = try #require(ScreenCaptureGeometry.resized(gray, to: ScreenPixelSize(width: 4, height: 4)))
        #expect(resized.width == 4 && resized.colorSpace?.model == .rgb)
    }

    @Test func snapshotFindsDisplaysByPointAndID() {
        let left = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2,
                                          image: ScreenCaptureTestSupport.image(width: 200, height: 200))
        let right = ScreenSnapshot.Display(id: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100), scale: 1,
                                           image: ScreenCaptureTestSupport.image(width: 100, height: 100))
        let snapshot = ScreenSnapshot(displays: [left, right], windows: [])
        #expect(snapshot.display(containing: CGPoint(x: 150, y: 50))?.id == 2)
        #expect(snapshot.display(containing: CGPoint(x: 50, y: 50))?.id == 1)
        #expect(snapshot.display(containing: CGPoint(x: 500, y: 50)) == nil)
        #expect(snapshot.display(id: 1)?.pixelSize == ScreenPixelSize(width: 200, height: 200))
        #expect(snapshot.display(id: 3) == nil)
    }
}
