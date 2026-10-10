import CoreGraphics
import Foundation

/// The annotations on one screenshot, front-most last, with undo and redo.
///
/// Annotations are values, so undo keeps whole snapshots of the list. A drag changes an
/// annotation many times without recording; `commit(from:)` then records the list as it was
/// before the drag, so the whole gesture undoes in one step.
struct ScreenshotAnnotationDocument: Equatable {
    /// How many steps undo keeps; older ones are dropped.
    static let historyLimit = 200

    private(set) var annotations: [ScreenshotAnnotation] = []
    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []

    init(annotations: [ScreenshotAnnotation] = []) {
        self.annotations = annotations
    }

    var isEmpty: Bool { annotations.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoDepth: Int { undoStack.count }

    func annotation(id: UUID) -> ScreenshotAnnotation? {
        annotations.first { $0.id == id }
    }

    /// The front-most annotation under a point.
    func hit(at point: CGPoint) -> ScreenshotAnnotation? {
        annotations.last { $0.contains(point) }
    }

    /// 1, 2, 3… in the order the counters were placed; removing one renumbers the rest.
    func counterNumber(of id: UUID) -> Int? {
        Self.counterNumbers(in: annotations)[id]
    }

    static func counterNumbers(in annotations: [ScreenshotAnnotation]) -> [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        for annotation in annotations {
            if case .counter = annotation.kind { numbers[annotation.id] = numbers.count + 1 }
        }
        return numbers
    }

    // MARK: Changes

    mutating func add(_ annotation: ScreenshotAnnotation) {
        record()
        annotations.append(annotation)
    }

    /// - Returns: false when no annotation has that id.
    @discardableResult
    mutating func remove(id: UUID) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        record()
        annotations.remove(at: index)
        return true
    }

    /// Replaces the annotation with the same id. With `recordingUndo` false the change joins
    /// the gesture in progress, and `commit(from:)` records it later.
    /// - Returns: false when no annotation has that id or nothing changed.
    @discardableResult
    mutating func update(_ annotation: ScreenshotAnnotation, recordingUndo: Bool = true) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }),
              annotations[index] != annotation else { return false }
        if recordingUndo { record() }
        annotations[index] = annotation
        return true
    }

    /// Records `previous` as one undo step, when the list differs from it.
    mutating func commit(from previous: [ScreenshotAnnotation]) {
        guard previous != annotations else { return }
        record(previous)
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(annotations)
        annotations = next
        return true
    }

    private mutating func record(_ state: [ScreenshotAnnotation]? = nil) {
        undoStack.append(state ?? annotations)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
        redoStack.removeAll()
    }
}
