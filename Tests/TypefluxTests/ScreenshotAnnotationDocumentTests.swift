import CoreGraphics
@testable import Typeflux
import XCTest

final class ScreenshotAnnotationDocumentTests: XCTestCase {
    private func rect(_ x: CGFloat, id: UUID = UUID()) -> ScreenshotAnnotation {
        ScreenshotAnnotation(id: id, kind: .rect(CGRect(x: x, y: 0, width: 10, height: 10)))
    }

    private func counter(_ x: CGFloat) -> ScreenshotAnnotation {
        ScreenshotAnnotation(kind: .counter(center: CGPoint(x: x, y: 50)))
    }

    func testAddRemoveAndUpdateRecordUndoSteps() {
        var document = ScreenshotAnnotationDocument()
        XCTAssertTrue(document.isEmpty)
        XCTAssertFalse(document.canUndo)
        let first = rect(0), second = rect(20)

        document.add(first)
        document.add(second)
        XCTAssertEqual(document.annotations, [first, second])
        XCTAssertEqual(document.undoDepth, 2)

        var moved = first
        moved.kind = .rect(CGRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertTrue(document.update(moved))
        XCTAssertFalse(document.update(moved), "Nothing changed")
        XCTAssertFalse(document.update(rect(0)), "Unknown id")
        XCTAssertEqual(document.annotation(id: first.id), moved)

        XCTAssertTrue(document.remove(id: second.id))
        XCTAssertFalse(document.remove(id: second.id))
        XCTAssertEqual(document.annotations, [moved])
        XCTAssertEqual(document.undoDepth, 4)

        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.annotations, [moved, second])
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.annotations, [first, second])
        XCTAssertTrue(document.canRedo)
        XCTAssertTrue(document.redo())
        XCTAssertEqual(document.annotations, [moved, second])

        // A new change drops what could be redone.
        document.add(rect(40))
        XCTAssertFalse(document.canRedo)
        XCTAssertFalse(document.redo())
    }

    func testUndoAndRedoAHundredStepsRestoreEveryState() {
        var document = ScreenshotAnnotationDocument()
        var states: [[ScreenshotAnnotation]] = [document.annotations]
        for step in 0 ..< 100 {
            switch step % 3 {
            case 0, 1:
                document.add(rect(CGFloat(step)))
            default:
                var changed = document.annotations[0]
                changed.style.color = changed.style.color == .red ? .blue : .red
                document.update(changed)
            }
            states.append(document.annotations)
        }
        XCTAssertEqual(document.undoDepth, 100)

        for expected in states.reversed().dropFirst() {
            XCTAssertTrue(document.undo())
            XCTAssertEqual(document.annotations, expected)
        }
        XCTAssertFalse(document.undo())
        for expected in states.dropFirst() {
            XCTAssertTrue(document.redo())
            XCTAssertEqual(document.annotations, expected)
        }
        XCTAssertFalse(document.redo())
    }

    func testHistoryKeepsTheNewestStepsOnly() {
        var document = ScreenshotAnnotationDocument()
        for step in 0 ..< ScreenshotAnnotationDocument.historyLimit + 5 {
            document.add(rect(CGFloat(step)))
        }
        XCTAssertEqual(document.undoDepth, ScreenshotAnnotationDocument.historyLimit)
        while document.undo() {}
        XCTAssertEqual(document.annotations.count, 5, "The five oldest steps can no longer be undone")
    }

    func testAGestureUndoesInOneStep() {
        var document = ScreenshotAnnotationDocument(annotations: [rect(0)])
        let before = document.annotations
        var moving = before[0]
        for offset in 1 ... 10 {
            moving = before[0].offsetBy(dx: CGFloat(offset), dy: 0)
            document.update(moving, recordingUndo: false)
        }
        XCTAssertFalse(document.canUndo)

        document.commit(from: before)
        XCTAssertEqual(document.undoDepth, 1)
        document.commit(from: document.annotations)
        XCTAssertEqual(document.undoDepth, 1, "Nothing changed, nothing recorded")

        document.undo()
        XCTAssertEqual(document.annotations, before)
        document.redo()
        XCTAssertEqual(document.annotations, [moving])
    }

    func testHitPicksTheFrontMostAnnotation() {
        let back = ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 10, y: 10)))
        let front = ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 14, y: 10)))
        let document = ScreenshotAnnotationDocument(annotations: [back, front])

        XCTAssertEqual(document.hit(at: CGPoint(x: 12, y: 10)), front)
        XCTAssertEqual(document.hit(at: CGPoint(x: -4, y: 10)), back)
        XCTAssertNil(document.hit(at: CGPoint(x: 100, y: 100)))
    }

    func testCountersRenumberWhenOneIsRemoved() {
        let one = counter(10), two = counter(40), three = counter(70)
        var document = ScreenshotAnnotationDocument(annotations: [one, rect(0), two, three])
        XCTAssertEqual(document.counterNumber(of: one.id), 1)
        XCTAssertEqual(document.counterNumber(of: two.id), 2)
        XCTAssertEqual(document.counterNumber(of: three.id), 3)
        XCTAssertNil(document.counterNumber(of: document.annotations[1].id), "Not a counter")

        document.remove(id: two.id)
        XCTAssertEqual(document.counterNumber(of: one.id), 1)
        XCTAssertEqual(document.counterNumber(of: three.id), 2)

        document.undo()
        XCTAssertEqual(document.counterNumber(of: three.id), 3)
    }
}
