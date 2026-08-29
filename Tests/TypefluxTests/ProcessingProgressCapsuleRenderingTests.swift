import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

final class ProcessingProgressCapsuleRenderingTests: XCTestCase {
    @MainActor
    func testThinkingCapsuleRendersEachProcessingStageFurtherForward() throws {
        let stages: [CGFloat] = [0.5, 0.7, 0.95, 1]

        for style in OverlayStyle.allCases {
            let images = try stages.map { progress in
                try render(
                    ThinkingProgressCapsule(title: "Thinking", progress: progress)
                        .environment(\.overlayStyle, style)
                        .frame(width: 132, height: 35),
                    size: CGSize(width: 132, height: 35)
                )
            }

            assertIncreasingBrightness(images, stages: stages, context: style.rawValue)
            assertStageImagesDiffer(images, context: style.rawValue)
        }
    }

    @MainActor
    func testTranscriptCapsuleRendersEachProcessingStageFurtherForward() throws {
        let stages: [CGFloat] = [0.5, 0.7, 0.95, 1]

        for style in OverlayStyle.allCases {
            let images = try stages.map { progress in
                try render(
                    ProcessingTranscriptCapsule(
                        text: "A stable transcript preview",
                        title: "Thinking",
                        progress: progress
                    )
                    .environment(\.overlayStyle, style),
                    size: CGSize(width: 360, height: 127)
                )
            }

            assertIncreasingBrightness(images, stages: stages, context: style.rawValue)
            assertStageImagesDiffer(images, context: style.rawValue)
        }
    }

    @MainActor
    func testThinkingCapsuleVisiblyMovesDuringFirstFiveSecondsOfLLMProcessing() throws {
        let progress = typicalLLMProgressCheckpoints()

        for style in OverlayStyle.allCases {
            let images = try progress.map { value in
                try render(
                    ThinkingProgressCapsule(title: "Thinking", progress: value)
                        .environment(\.overlayStyle, style)
                        .frame(width: 132, height: 35),
                    size: CGSize(width: 132, height: 35)
                )
            }

            assertStageImagesDiffer(images, context: "\(style.rawValue) first five seconds")
        }
    }

    @MainActor
    func testTranscriptCapsuleVisiblyMovesDuringFirstFiveSecondsOfLLMProcessing() throws {
        let progress = typicalLLMProgressCheckpoints()

        for style in OverlayStyle.allCases {
            let images = try progress.map { value in
                try render(
                    ProcessingTranscriptCapsule(
                        text: "A stable transcript preview",
                        title: "Thinking",
                        progress: value
                    )
                    .environment(\.overlayStyle, style),
                    size: CGSize(width: 360, height: 127)
                )
            }

            assertStageImagesDiffer(images, context: "\(style.rawValue) first five seconds")
        }
    }

    private func typicalLLMProgressCheckpoints() -> [CGFloat] {
        let timeline = ProcessingProgressTimeline(timeout: 120)
        return [30.0, 31.0, 33.0, 35.0].map {
            timeline.progress(elapsed: $0, contentProcessingStartedAt: 30)
        }
    }

    private func assertIncreasingBrightness(
        _ images: [NSBitmapImageRep],
        stages: [CGFloat],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let brightness = images.map(\.meanBrightness)

        for index in 1 ..< brightness.count {
            XCTAssertGreaterThan(
                brightness[index],
                brightness[index - 1],
                "\(context): rendered brightness must increase from \(stages[index - 1]) to \(stages[index])",
                file: file,
                line: line
            )
        }
    }

    private func assertStageImagesDiffer(
        _ images: [NSBitmapImageRep],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 1 ..< images.count {
            XCTAssertTrue(
                images[index - 1].differsVisibly(from: images[index]),
                "\(context): adjacent processing stages must render visibly different fills",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func render<Content: View>(
        _ content: Content,
        size: CGSize
    ) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }
}

private extension NSBitmapImageRep {
    var meanBrightness: CGFloat {
        var total: CGFloat = 0
        var samples = 0

        for y in 0 ..< pixelsHigh {
            for x in 0 ..< pixelsWide {
                guard let color = colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                samples += 1
            }
        }

        return samples == 0 ? 0 : total / CGFloat(samples)
    }

    func differsVisibly(from other: NSBitmapImageRep) -> Bool {
        guard pixelsWide == other.pixelsWide, pixelsHigh == other.pixelsHigh else {
            return true
        }

        var changedPixels = 0
        let requiredChangedPixels = max(1, pixelsWide * pixelsHigh / 1_000)

        for y in 0 ..< pixelsHigh {
            for x in 0 ..< pixelsWide {
                guard let lhs = colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let rhs = other.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }

                let difference = abs(lhs.redComponent - rhs.redComponent)
                    + abs(lhs.greenComponent - rhs.greenComponent)
                    + abs(lhs.blueComponent - rhs.blueComponent)
                    + abs(lhs.alphaComponent - rhs.alphaComponent)
                if difference > 0.05 {
                    changedPixels += 1
                    if changedPixels >= requiredChangedPixels {
                        return true
                    }
                }
            }
        }

        return false
    }
}
