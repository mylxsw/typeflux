import CoreGraphics
@testable import Typeflux
import XCTest

final class ScreenshotAnnotationTests: XCTestCase {
    func testStyleSizesGrowWithTheWidth() {
        let thin = ScreenshotAnnotationStyle(width: .thin), thick = ScreenshotAnnotationStyle(width: .thick)
        for size in [\ScreenshotAnnotationStyle.lineWidth, \.highlighterWidth, \.fontSize, \.counterDiameter,
                     \.brushWidth] {
            XCTAssertLessThan(thin[keyPath: size], ScreenshotAnnotationStyle()[keyPath: size])
            XCTAssertLessThan(ScreenshotAnnotationStyle()[keyPath: size], thick[keyPath: size])
        }
        XCTAssertEqual(ScreenshotAnnotationStyle.Color.allCases.count, 5)
        XCTAssertEqual(ScreenshotAnnotationStyle.Color.blue.cgColor().components?.map { ($0 * 255).rounded() },
                       [0x2F, 0x8C, 0xFF, 255])
        XCTAssertEqual(ScreenshotAnnotationStyle.Color.red.cgColor(alpha: 0.4).alpha, 0.4, accuracy: 0.001)
        XCTAssertNotEqual(ScreenshotAnnotationStyle.Color.white.contrastingTextColor,
                          ScreenshotAnnotationStyle.Color.red.contrastingTextColor)
        XCTAssertEqual(ScreenshotAnnotationStyle.Color.yellow.contrastingTextColor,
                       ScreenshotAnnotationStyle.Color.white.contrastingTextColor)
    }

    func testFramesOfEveryKind() {
        let style = ScreenshotAnnotationStyle()
        XCTAssertEqual(ScreenshotAnnotation(kind: .rect(CGRect(x: 10, y: 10, width: -5, height: 5))).frame,
                       CGRect(x: 5, y: 10, width: 5, height: 5), "Standardized")
        XCTAssertEqual(ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 9, y: 1), to: CGPoint(x: 1, y: 5))).frame,
                       CGRect(x: 1, y: 1, width: 8, height: 4))
        XCTAssertEqual(ScreenshotAnnotation(kind: .path([CGPoint(x: 3, y: 4), CGPoint(x: 1, y: 8),
                                                         CGPoint(x: 6, y: 5)])).frame,
                       CGRect(x: 1, y: 4, width: 5, height: 4))
        XCTAssertEqual(ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 50, y: 50))).frame,
                       CGRect(x: 38, y: 38, width: style.counterDiameter, height: style.counterDiameter))
        let text = ScreenshotAnnotation(kind: .text(origin: CGPoint(x: 5, y: 5), "Hello", fontSize: 18)).frame
        XCTAssertEqual(text.origin, CGPoint(x: 5, y: 5))
        XCTAssertGreaterThan(text.width, 30)
        XCTAssertGreaterThan(text.height, 18)
        let brush = ScreenshotMosaic(shape: .brush([CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)], width: 8))
        XCTAssertEqual(brush.frame, CGRect(x: 6, y: 6, width: 28, height: 8))
        XCTAssertEqual(ScreenshotAnnotation(kind: .mosaic(brush)).frame, brush.frame)
        XCTAssertTrue(ScreenshotAnnotation.boundingBox(of: []).isNull)
    }

    func testTextSize() {
        let empty = ScreenshotAnnotation.textSize("", fontSize: 18)
        XCTAssertEqual(empty.width, 0)
        XCTAssertGreaterThan(empty.height, 18, "An empty line still has a line's height")
        let twoLines = ScreenshotAnnotation.textSize("a\nb", fontSize: 18)
        XCTAssertGreaterThan(twoLines.height, empty.height * 1.5)
        XCTAssertEqual(ScreenshotAnnotation.font(size: 12).pointSize, 12)
    }

    func testMovingKeepsTheShape() {
        let kinds: [ScreenshotAnnotation.Kind] = [
            .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
            .ellipse(CGRect(x: 0, y: 0, width: 10, height: 10)),
            .arrow(from: .zero, to: CGPoint(x: 10, y: 10)),
            .path([.zero, CGPoint(x: 10, y: 10)]),
            .highlight([.zero, CGPoint(x: 10, y: 10)]),
            .text(origin: .zero, "Hi", fontSize: 12),
            .counter(center: .zero),
            .mosaic(ScreenshotMosaic(shape: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)))),
            .mosaic(ScreenshotMosaic(shape: .brush([.zero, CGPoint(x: 10, y: 10)], width: 6)))
        ]
        for kind in kinds {
            let annotation = ScreenshotAnnotation(kind: kind)
            let moved = annotation.offsetBy(dx: 5, dy: -3)
            XCTAssertEqual(moved.id, annotation.id)
            XCTAssertEqual(moved.frame, annotation.frame.offsetBy(dx: 5, dy: -3), "\(kind)")
            XCTAssertEqual(moved.offsetBy(dx: -5, dy: 3), annotation)
        }
        let mosaic = ScreenshotMosaic(shape: .rect(CGRect(x: 0, y: 0, width: 4, height: 4)))
        XCTAssertEqual(mosaic.offsetBy(dx: 1, dy: 2).frame, CGRect(x: 1, y: 2, width: 4, height: 4))
        let brush = ScreenshotMosaic(shape: .brush([.zero], width: 4))
        XCTAssertEqual(brush.offsetBy(dx: 1, dy: 2).shape, .brush([CGPoint(x: 1, y: 2)], width: 4))
    }

    func testResizingStretchesPointsAndScalesText() {
        let box = ScreenshotAnnotation(kind: .rect(CGRect(x: 10, y: 10, width: 10, height: 20)))
        XCTAssertEqual(box.resized(from: box.frame, to: CGRect(x: 0, y: 0, width: 30, height: 10)).frame,
                       CGRect(x: 0, y: 0, width: 30, height: 10))

        let arrow = ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 0, y: 10), to: CGPoint(x: 10, y: 0)))
        XCTAssertEqual(arrow.resized(from: arrow.frame, to: CGRect(x: 0, y: 0, width: 20, height: 20)).kind,
                       .arrow(from: CGPoint(x: 0, y: 20), to: CGPoint(x: 20, y: 0)))

        let line = ScreenshotAnnotation(kind: .path([CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 5)]))
        XCTAssertEqual(line.resized(from: line.frame, to: CGRect(x: 0, y: 0, width: 20, height: 0)).kind,
                       .path([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0)]), "A flat frame keeps its scale of 1")

        let text = ScreenshotAnnotation(kind: .text(origin: CGPoint(x: 10, y: 10), "Hi", fontSize: 20))
        let shrunk = text.resized(from: CGRect(x: 10, y: 10, width: 20, height: 20),
                                  to: CGRect(x: 10, y: 10, width: 1, height: 1))
        XCTAssertEqual(shrunk.kind, .text(origin: CGPoint(x: 10, y: 10), "Hi",
                                          fontSize: ScreenshotAnnotation.minimumFontSize))

        let brush = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .brush([.zero, CGPoint(x: 10, y: 10)],
                                                                                        width: 4))))
        XCTAssertEqual(brush.resized(from: CGRect(x: 0, y: 0, width: 10, height: 10),
                                     to: CGRect(x: 0, y: 0, width: 20, height: 20)).mosaic?.shape,
                       .brush([.zero, CGPoint(x: 20, y: 20)], width: 4))
        let mosaic = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect(CGRect(x: 0, y: 0, width: 10,
                                                                                            height: 10)))))
        XCTAssertEqual(mosaic.resized(from: mosaic.frame, to: CGRect(x: 5, y: 5, width: 5, height: 5)).frame,
                       CGRect(x: 5, y: 5, width: 5, height: 5))
        let ellipse = ScreenshotAnnotation(kind: .ellipse(CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertEqual(ellipse.resized(from: ellipse.frame, to: CGRect(x: 0, y: 0, width: 4, height: 8)).frame,
                       CGRect(x: 0, y: 0, width: 4, height: 8))
        let highlight = ScreenshotAnnotation(kind: .highlight([.zero, CGPoint(x: 10, y: 10)]))
        XCTAssertEqual(highlight.resized(from: highlight.frame, to: CGRect(x: 0, y: 0, width: 5, height: 5)).frame,
                       CGRect(x: 0, y: 0, width: 5, height: 5))
        let counter = ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(counter.isResizable)
        XCTAssertTrue(box.isResizable)
    }

    func testHitTesting() {
        let box = ScreenshotAnnotation(kind: .rect(CGRect(x: 10, y: 10, width: 40, height: 40)))
        XCTAssertTrue(box.contains(CGPoint(x: 10, y: 30)), "On the outline")
        XCTAssertTrue(box.contains(CGPoint(x: 5, y: 30)), "Within reach")
        XCTAssertFalse(box.contains(CGPoint(x: 30, y: 30)), "The middle of an outline is empty")
        XCTAssertFalse(box.contains(CGPoint(x: 0, y: 30)))
        let tiny = ScreenshotAnnotation(kind: .rect(CGRect(x: 10, y: 10, width: 4, height: 4)))
        XCTAssertTrue(tiny.contains(CGPoint(x: 12, y: 12)), "A tiny box is hit anywhere")

        let ellipse = ScreenshotAnnotation(kind: .ellipse(CGRect(x: 0, y: 0, width: 40, height: 20)))
        XCTAssertTrue(ellipse.contains(CGPoint(x: 0, y: 10)))
        XCTAssertFalse(ellipse.contains(CGPoint(x: 20, y: 10)))

        let arrow = ScreenshotAnnotation(kind: .arrow(from: .zero, to: CGPoint(x: 100, y: 0)))
        XCTAssertTrue(arrow.contains(CGPoint(x: 50, y: 6)))
        XCTAssertFalse(arrow.contains(CGPoint(x: 50, y: 20)))
        XCTAssertFalse(arrow.contains(CGPoint(x: 120, y: 0)), "Past the tip")

        let pen = ScreenshotAnnotation(kind: .path([.zero, CGPoint(x: 50, y: 0)]))
        XCTAssertTrue(pen.contains(CGPoint(x: 25, y: 3)))
        XCTAssertFalse(pen.contains(CGPoint(x: 25, y: 12)))
        let marker = ScreenshotAnnotation(kind: .highlight([.zero, CGPoint(x: 50, y: 0)]))
        XCTAssertTrue(marker.contains(CGPoint(x: 25, y: 12)), "Highlighters are wider")

        let text = ScreenshotAnnotation(kind: .text(origin: .zero, "Hello", fontSize: 18))
        XCTAssertTrue(text.contains(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(text.contains(CGPoint(x: 200, y: 10)))

        let counter = ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 50, y: 50)))
        XCTAssertTrue(counter.contains(CGPoint(x: 60, y: 50)))
        XCTAssertFalse(counter.contains(CGPoint(x: 80, y: 50)))

        let mosaic = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect(CGRect(x: 0, y: 0, width: 20,
                                                                                            height: 20)))))
        XCTAssertTrue(mosaic.contains(CGPoint(x: 10, y: 10)), "Mosaics are filled")
        let brush = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .brush([.zero, CGPoint(x: 40, y: 0)],
                                                                                      width: 10))))
        XCTAssertTrue(brush.contains(CGPoint(x: 20, y: 6)))
        XCTAssertFalse(brush.contains(CGPoint(x: 20, y: 20)))
    }

    func testGeometryHelpers() {
        XCTAssertEqual(ScreenshotAnnotation.distance(from: CGPoint(x: 3, y: 4), toSegment: .zero, .zero), 5)
        XCTAssertEqual(ScreenshotAnnotation.distance(from: CGPoint(x: 5, y: 2), toSegment: .zero,
                                                     CGPoint(x: 10, y: 0)), 2)
        XCTAssertTrue(ScreenshotAnnotation.polyline([]).isEmpty)
        XCTAssertFalse(ScreenshotAnnotation.polyline([.zero]).isEmpty, "One point is a dot")
        XCTAssertEqual(ScreenshotAnnotation.arrowHeadLength(lineWidth: 2), 12)
        XCTAssertEqual(ScreenshotAnnotation.arrowHeadLength(lineWidth: 6), 24)
        let mosaic = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect(.zero))))
        XCTAssertTrue(mosaic.isMosaic)
        XCTAssertNotNil(mosaic.mosaic)
        XCTAssertNil(ScreenshotAnnotation(kind: .counter(center: .zero)).mosaic)
        XCTAssertTrue(ScreenshotMosaic(shape: .rect(CGRect(x: 0, y: 0, width: 4, height: 4))).maskPath
            .contains(CGPoint(x: 2, y: 2)))
    }
}
