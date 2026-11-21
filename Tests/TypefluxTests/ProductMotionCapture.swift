import AppKit
import AVFoundation
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in, isolated native view movies. Records changes over real time, not still-image transitions.
@MainActor
final class ProductMotionCapture {
    let window: NSWindow
    let stage: NSView
    let size = CGSize(width: 1120, height: 740)
    private var hosts: [NSView] = []

    init() {
        _ = NSApplication.shared
        stage = NSView(frame: CGRect(x: 0, y: 0, width: 1120, height: 740))
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor(srgbRed: 20/255, green: 22/255, blue: 29/255, alpha: 1).cgColor
        window = AskTestVoiceWindow(contentRect: stage.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = stage
        window.setFrameOrigin(CGPoint(x: 80, y: 100))
        window.orderFrontRegardless()
    }

    @discardableResult
    func mount<V: View>(_ view: V, size: CGSize, origin: CGPoint? = nil) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark)
            .environment(\.askGlassMaterialOverride, .opaque))
        host.frame = CGRect(origin: origin ?? CGPoint(x: (self.size.width-size.width)/2, y: (self.size.height-size.height)/2), size: size)
        stage.addSubview(host); hosts.append(host)
        return host
    }

    func clear() { stage.subviews.forEach { $0.removeFromSuperview() }; hosts.removeAll() }
    func close() { clear(); window.orderOut(nil); window.close() }

    func record(_ name: String, duration: Double, directory: URL,
                update: (Double) async throws -> Void) async throws {
        if ProcessInfo.processInfo.environment["TYPEFLUX_MOTION_NATIVE_CAPTURE"] == "1" {
            try await recordWindow(name, duration: duration, directory: directory, update: update)
            return
        }
        let url = directory.appendingPathComponent(name + ".mov")
        try? FileManager.default.removeItem(at: url)
        let width = 2240, height = 1480
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        try #require(writer.canAdd(input)); writer.add(input); try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        try await Task.sleep(for: .milliseconds(120))
        let start = CACurrentMediaTime()
        var frames = 0
        while true {
            let t = CACurrentMediaTime() - start
            if t >= duration { break }
            try await update(t)
            try await Task.sleep(for: .milliseconds(2))
            stage.layoutSubtreeIfNeeded(); stage.displayIfNeeded()
            let bitmap = try #require(stage.bitmapImageRepForCachingDisplay(in: stage.bounds))
            stage.cacheDisplay(in: stage.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            if frames == 0 { try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + "-first.png")) }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixel: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil, #require(adaptor.pixelBufferPool), &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 60000)))
            frames += 1
            let remaining = (Double(frames) / 30) - (CACurrentMediaTime() - start)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
        input.markAsFinished(); await writer.finishWriting(); try #require(writer.status == .completed)
        print("MOTION \(name): \(frames) frames / \(duration)s")
    }
    private func recordWindow(_ name: String, duration: Double, directory: URL,
                              update: (Double) async throws -> Void) async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Native window recording requires an existing screen-capture grant")
        let url = directory.appendingPathComponent(name + ".mov")
        try? FileManager.default.removeItem(at: url)
        var options = ScreenRecordingOptions()
        options.systemAudio = false; options.microphone = false; options.camera = false
        options.showsCursor = false; options.framesPerSecond = 60
        options.maxDimension = 2560
        window.orderFrontRegardless(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let own = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }, "The isolated capture window must exist in the window server")
        let outputSize = CGSize(width: 2240, height: 1480)
        let plan = ScreenRecordingCapturePlan(filter: SCContentFilter(desktopIndependentWindow: own),
            configuration: ScreenRecordingCapturePlan.configuration(size: outputSize, sourceRect: nil, options: options), size: outputSize)
        let writer = try ScreenRecordingWriter(url: url, size: plan.size, options: options)
        let recording = ScreenRecordingCapture(writer: writer, options: options, onError: { error in
            print("MOTION capture error: \(error.localizedDescription)")
        })
        try await recording.start(plan: plan)
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < duration {
            try await update(CACurrentMediaTime() - start)
            try await Task.sleep(for: .milliseconds(16))
        }
        await recording.stop()
        _ = try await writer.finish(at: CACurrentMediaTime())
        print("MOTION native window \(name): \(duration)s")
    }

}
