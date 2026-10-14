import CoreMedia
import Foundation
import Testing
@testable import Typeflux

@Suite("Screen recording models")
struct ScreenRecordingModelsTests {
    @Test func `timeline removes multiple pauses and rejects late samples`() throws {
        var time = ScreenRecordingTimeline()
        #expect(time.position(at: 90) == nil)
        time.start(at: .nan)
        #expect(time.origin == nil)
        time.start(at: 100)
        time.start(at: 200)
        #expect(time.sampleTime(at: 99) == nil)
        #expect(time.sampleTime(at: 101) == 1)
        time.pause(at: 102)
        time.pause(at: 103)
        #expect(time.position(at: 110) == 2)
        #expect(time.sampleTime(at: 102) == nil)
        time.resume(at: 101)
        #expect(time.pausedAt == 102)
        time.resume(at: 105)
        #expect(time.sampleTime(at: 103) == nil)
        #expect(try #require(time.sampleTime(at: 105.1)) - 2.1 < 0.0001)
        time.pause(at: 110)
        time.resume(at: 114)
        #expect(time.position(at: 120) == 13)
        #expect(time.position(at: .nan) == nil)
        time.resume(at: 121)
        #expect(time.pauses.count == 2)
    }

    @Test func `pause before first frame does not create negative timestamps`() {
        var time = ScreenRecordingTimeline()
        time.pause(at: 10)
        time.start(at: 11)
        #expect(time.sampleTime(at: 11) == nil)
        time.resume(at: 12)
        #expect(time.sampleTime(at: 13) == 1)
    }

    @Test func `video size is even clamped and never upscaled`() throws {
        #expect(try ScreenRecordingGeometry.outputSize(points: CGSize(width: 1440, height: 900), scale: 2,
                                                       maxDimension: 1920) == CGSize(width: 1920, height: 1200))
        #expect(try ScreenRecordingGeometry.outputSize(points: CGSize(width: 101, height: 99), scale: 1,
                                                       maxDimension: 1920) == CGSize(width: 100, height: 98))
        #expect(try ScreenRecordingGeometry.outputSize(points: CGSize(width: 2, height: 3000), scale: 1,
                                                       maxDimension: 320) == CGSize(width: 2, height: 320))
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 100), CGSize(width: -1, height: 100)] {
            #expect(throws: ScreenRecordingFailure.unavailable) {
                try ScreenRecordingGeometry.outputSize(points: size, scale: 2, maxDimension: 1920)
            }
        }
    }

    @Test func `region converts negative display coordinates and clips at the edge`() throws {
        let display = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let local = try ScreenRecordingGeometry.sourceRect(
            CGRect(x: -2000, y: -100, width: 400, height: 200),
            on: display
        )
        #expect(local == CGRect(x: 0, y: 100, width: 320, height: 200))
        #expect(throws: ScreenRecordingFailure.unavailable) {
            try ScreenRecordingGeometry.sourceRect(CGRect(x: 10, y: 10, width: 100, height: 100), on: display)
        }
        #expect(throws: ScreenRecordingFailure.unavailable) {
            try ScreenRecordingGeometry.sourceRect(.infinite, on: display)
        }
    }

    @Test func `camera corners stay inside the video`() {
        let size = CGSize(width: 1920, height: 1080)
        for corner in ScreenRecordingOptions.CameraCorner.allCases {
            let frame = ScreenRecordingGeometry.cameraRect(in: size, fraction: 0.22, corner: corner)
            #expect(CGRect(origin: .zero, size: size).contains(frame))
            #expect(frame.width == size.width * 0.22)
            if corner == .topLeft || corner == .topRight {
                #expect(frame.minY > size.height / 2)
            } else {
                #expect(frame.maxY < size.height / 2)
            }
        }
        #expect(ScreenRecordingGeometry.cameraRect(in: size, fraction: 1, corner: .bottomLeft).width == 768)
    }

    @Test func `preferences round trip and GIF disables audio`() throws {
        let suite = "recording-models-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ScreenRecordingOptions.load(from: defaults) == ScreenRecordingOptions())
        defaults.set(Data("invalid".utf8), forKey: "screenshot.recording.options")
        #expect(ScreenRecordingOptions.load(from: defaults) == ScreenRecordingOptions())
        var options = ScreenRecordingOptions()
        options.camera = true
        options.microphone = true
        options.systemAudio = true
        options.cameraCorner = .topLeft
        options.framesPerSecond = 1000
        options.maxDimension = 10000
        #expect(options.captureFPS == 60)
        #expect(options.dimension == 3840)
        #expect(options.durationLimit == nil)
        #expect(options.capturesAudio)
        options.format = .gif
        #expect(options.captureFPS == 10)
        #expect(options.dimension == 960)
        #expect(options.durationLimit == 30)
        #expect(!options.capturesAudio)
        options.save(to: defaults)
        #expect(ScreenRecordingOptions.load(from: defaults) == options)
        options.format = .mp4
        options.framesPerSecond = -1
        options.maxDimension = -1
        #expect(options.captureFPS == 10)
        #expect(options.dimension == 320)
    }

    @Test func `trim validation rejects empty reversed and oversized GIF`() throws {
        let range = try ScreenRecordingTrim(start: 1, end: 2.5).validated(duration: 3, format: .mp4)
        #expect(range.start.seconds == 1)
        #expect(range.duration.seconds == 1.5)
        for trim in [ScreenRecordingTrim(start: -1, end: 2), .init(start: 2, end: 1),
                     .init(start: 1, end: 1), .init(start: 0, end: 31), .init(start: .nan, end: 2)] {
            #expect(throws: ScreenRecordingFailure.invalidRange) { try trim.validated(duration: 30, format: .gif) }
        }
        #expect(throws: ScreenRecordingFailure.invalidRange) {
            try ScreenRecordingTrim(start: 0, end: 31).validated(duration: 60, format: .gif)
        }
        #expect(try ScreenRecordingTrim(start: 5, end: 35).validated(duration: 60, format: .gif).duration.seconds == 30)
    }

    @Test func `publication never overwrites and recovery is scoped`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ScreenRecordingFiles(root: root.appendingPathComponent("sessions"))
        #expect(files.recoverableSources().isEmpty)
        let session = try files.createSession(options: ScreenRecordingOptions())
        let source = session.appendingPathComponent("source.mov")
        try Data([1, 2, 3]).write(to: source)
        #expect(files.recoverableSources().map { $0.resolvingSymlinksInPath() } == [source.resolvingSymlinksInPath()])
        let destination = root.appendingPathComponent("saved")
        let first = try files.publish(source, in: destination, format: .mp4, date: Date(timeIntervalSince1970: 0))
        let second = try files.publish(source, in: destination, format: .mp4, date: Date(timeIntervalSince1970: 0))
        #expect(first != second)
        #expect(second.lastPathComponent.contains("(2)"))
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 2)
        files.discard(destination)
        #expect(FileManager.default.fileExists(atPath: first.path))
        files.discard(session)
        #expect(files.recoverableSources().isEmpty)
    }
}
