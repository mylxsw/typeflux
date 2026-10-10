import CoreGraphics
@testable import Typeflux

/// A fixed, synthetic page for scrolling capture tests, and the frames a scrolling region would
/// show of it: lines of "text" (rows of pseudo-random dark marks, different on every row) with
/// light gaps between them, under an optional pinned header and over an optional bottom bar.
enum ScrollCaptureFixtures {
    typealias Pixels = ScreenshotMosaicEffects.Pixels
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    struct Page {
        var width: Int
        var height: Int
        /// RGBA, top row first.
        var bytes: [UInt8]
        var header: [UInt8] = []
        var headerHeight = 0
        var footer: [UInt8] = []
        var footerHeight = 0

        /// What the region shows when the page is scrolled down by `offset` rows.
        func frame(offset: Int, scrollingHeight: Int) -> ScrollFrame {
            ScrollFrame(image: frameImage(offset: offset, scrollingHeight: scrollingHeight))!
        }

        func frameImage(offset: Int, scrollingHeight: Int) -> CGImage {
            let rowBytes = width * 4
            var out = header
            out += bytes[offset * rowBytes ..< (offset + scrollingHeight) * rowBytes]
            out += footer
            return Pixels(width: width, height: headerHeight + scrollingHeight + footerHeight, bytes: out)
                .makeImage(space: space)!
        }

        /// The long image the stitcher should make after scrolling down to `lastOffset`.
        func expected(lastOffset: Int, scrollingHeight: Int) -> [UInt8] {
            let rowBytes = width * 4
            return header + Array(bytes[0 ..< (lastOffset + scrollingHeight) * rowBytes]) + footer
        }
    }

    /// A deterministic generator, so every run sees the same page.
    struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }

    /// Lines of 14 rows of marks with 6-row gaps; every gap has its own light tone, so no two rows
    /// anywhere on the page are the same.
    static func page(width: Int = 96, height: Int = 1600, header: Int = 0, footer: Int = 0,
                     seed: UInt64 = 7) -> Page {
        var generator = Generator(state: seed)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0 ..< height {
            let line = row / 20, inLine = row % 20
            for column in 0 ..< width {
                let offset = (row * width + column) * 4
                let value: UInt8
                if inLine < 14 {
                    value = generator.next() % 3 == 0 ? UInt8(generator.next() % 120) : 250
                } else {
                    // Light and nearly flat: too little detail to align on.
                    value = UInt8(240 - (line + inLine) % 12)
                }
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        var page = Page(width: width, height: height, bytes: bytes)
        page.headerHeight = header
        page.header = bar(width: width, height: header, red: 40, generator: &generator)
        page.footerHeight = footer
        page.footer = bar(width: width, height: footer, red: 200, generator: &generator)
        return page
    }

    /// A colored bar with marks on it, like a toolbar.
    private static func bar(width: Int, height: Int, red: UInt8, generator: inout Generator) -> [UInt8] {
        var bytes: [UInt8] = []
        for _ in 0 ..< height * width {
            let mark = generator.next() % 4 == 0
            bytes += [mark ? 255 : red, mark ? 255 : 90, mark ? 255 : 160, 255]
        }
        return bytes
    }

    /// Random noise: lines up with nothing.
    static func noise(width: Int, height: Int, seed: UInt64) -> CGImage {
        var generator = Generator(state: seed)
        var bytes: [UInt8] = []
        for _ in 0 ..< width * height {
            let value = UInt8(generator.next() % 256)
            bytes += [value, value, value, 255]
        }
        return Pixels(width: width, height: height, bytes: bytes).makeImage(space: space)!
    }

    /// One flat color.
    static func solid(width: Int, height: Int, gray: UInt8) -> CGImage {
        let bytes = [UInt8](repeating: gray, count: width * height * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }
        return Pixels(width: width, height: height, bytes: bytes).makeImage(space: space)!
    }

    static func bytes(of image: CGImage) -> [UInt8] {
        Pixels(image, space: space)!.bytes
    }
}
