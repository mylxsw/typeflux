import CoreGraphics
import Testing
@testable import Typeflux

struct ScreenRecordingLayoutTests {
    @Test func `capsule prefers below then above then inside and stays on screen`() {
        let screen = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        let size = CGSize(width: 300, height: 40)
        let below = ScreenRecordingLayout.capsule(
            target: CGRect(x: -800, y: 200, width: 500, height: 400),
            size: size,
            screen: screen
        )
        #expect(below.maxY == 188)
        let above = ScreenRecordingLayout.capsule(
            target: CGRect(x: -1100, y: 0, width: 500, height: 400),
            size: size,
            screen: screen
        )
        #expect(above.minY == 412)
        let inside = ScreenRecordingLayout.capsule(target: screen, size: size, screen: screen)
        #expect(inside.minY == 12)
        #expect(screen.contains(inside))
        let edge = ScreenRecordingLayout.capsule(
            target: CGRect(x: -20, y: 0, width: 20, height: 800),
            size: size,
            screen: screen
        )
        #expect(screen.contains(edge))
    }

    @Test func `timeline coordinates round trip with clamping and invalid inputs`() {
        for value in [0.0, 2.5, 10, 30] {
            let x = ScreenRecordingLayout.position(time: value, width: 900, duration: 30)
            #expect(abs(ScreenRecordingLayout.time(at: x, width: 900, duration: 30) - value) < 0.0001)
        }
        #expect(ScreenRecordingLayout.time(at: -100, width: 900, duration: 30) == 0)
        #expect(ScreenRecordingLayout.time(at: 1000, width: 900, duration: 30) == 30)
        #expect(ScreenRecordingLayout.time(at: .nan, width: 0, duration: .infinity) == 0)
        #expect(ScreenRecordingLayout.position(time: .nan, width: 900, duration: 0) == 0)
        #expect(ScreenRecordingLayout.position(time: 40, width: 900, duration: 30) == 900)
    }

    @Test func `camera maps to four corners and valid size limits`() {
        let size = CGSize(width: 1000, height: 600)
        #expect(ScreenRecordingLayout.cameraCorner(at: CGPoint(x: 100, y: 100), in: size) == .topLeft)
        #expect(ScreenRecordingLayout.cameraCorner(at: CGPoint(x: 900, y: 100), in: size) == .topRight)
        #expect(ScreenRecordingLayout.cameraCorner(at: CGPoint(x: 100, y: 500), in: size) == .bottomLeft)
        #expect(ScreenRecordingLayout.cameraCorner(at: CGPoint(x: 900, y: 500), in: size) == .bottomRight)
        #expect(ScreenRecordingLayout.cameraFraction(width: 50, targetWidth: 1000) == 0.12)
        #expect(ScreenRecordingLayout.cameraFraction(width: 900, targetWidth: 1000) == 0.4)
        #expect(ScreenRecordingLayout.cameraFraction(width: 220, targetWidth: 1000) == 0.22)
        #expect(ScreenRecordingLayout.cameraFraction(width: .nan, targetWidth: 0) == 0.22)
        #expect(!ScreenRecordingLayout.validRegion(CGRect(x: 0, y: 0, width: 39, height: 500)))
        #expect(ScreenRecordingLayout.validRegion(CGRect(x: 0, y: 0, width: 40, height: 40)))
    }

    @Test func `file names cannot escape the chosen directory`() {
        #expect(ScreenRecordingLayout.fileName(" ../../escape\nname ") == "..-..-escape-name")
        #expect(ScreenRecordingLayout.fileName("..") == "Typeflux Recording")
        #expect(ScreenRecordingLayout.fileName(" ") == "Typeflux Recording")
        #expect(ScreenRecordingLayout.fileName(String(repeating: "x", count: 300)).count == 180)
        #expect(ScreenRecordingLayout.preciseTime(65.25) == "01:05.2")
        #expect(ScreenRecordingLayout.preciseTime(.nan) == "00:00.0")
    }
}
