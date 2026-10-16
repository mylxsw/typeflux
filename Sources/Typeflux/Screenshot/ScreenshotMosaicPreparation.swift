import AppKit
import TypefluxMediaProtocol

/// One owned preparation per editor. Cancellation does not release its slot until work returns.
@MainActor
final class ScreenshotMosaicPreparation {
    enum State: Equatable {
        case idle, preparing, ready, unavailable, retired
        var noticeKey: String? {
            switch self {
            case .preparing: "screenshot.mosaic.preparing"
            case .unavailable, .retired: "screenshot.mosaic.unavailable"
            case .idle, .ready: nil
            }
        }
    }
    var onChange: (() -> Void)?
    private(set) var state = State.idle
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var attempted: UUID?
    private var generation = UUID()
    private var snapshot: ScreenshotAnnotationDocument?
    private var region: CGRect?
    private var selection: UUID?
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retire() }
            })
        }
    }
    deinit { task?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }

    func cancel() {
        generation = UUID(); task?.cancel(); snapshot = nil; region = nil
        if state != .retired { state = .unavailable }
    }
    func retire() { cancel(); state = .retired; onChange?() }

    func update(editor: ScreenshotAnnotationEditor, region: CGRect?,
                prepare: @escaping (ScreenshotMosaic) async throws -> ScreenshotTextGeometry,
                commit: @escaping (UUID, ScreenshotTextGeometry) -> Void) {
        guard state != .retired else { return }
        if task != nil, snapshot != editor.document || self.region != region || editor.isDragging || editor.geometryRequest?.id != attempted || selection != editor.selectedID {
            cancel()
        }
        guard state != .retired, let request = editor.geometryRequest, attempted != request.id else { return }
        attempted = request.id
        guard task == nil, region != nil, !editor.isDragging else { state = .unavailable; return }
        let token = UUID(); generation = token; snapshot = editor.document; self.region = region; selection = editor.selectedID
        state = .preparing; taskID = token
        task = Task { [weak self] in
            defer { if self?.taskID == token { self?.task = nil; self?.taskID = nil } }
            do {
                try Task.checkCancellation()
                let geometry = try await prepare(request.mosaic)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.state != .retired else { return }
                self.state = .ready
                self.task = nil; self.taskID = nil; self.snapshot = nil
                commit(request.id, geometry)
            } catch {
                guard let self, self.generation == token, self.state != .retired else { return }
                self.state = .unavailable; self.snapshot = nil; self.onChange?()
            }
        }
    }

    static func prepare(_ mosaic: ScreenshotMosaic, crop: CGRect, image: CGImage, bounds: CGRect,
                        measurer: any ScreenshotTextHeightMeasuring) async throws -> ScreenshotTextGeometry {
        guard [mosaic.frame, crop, bounds].allSatisfy({ rect in
            [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
        }) else { throw MediaFailure.unreadable }
        let region = mosaic.frame.intersection(crop)
        guard !region.isNull, let pixels = ScreenCaptureGeometry.pixelRect(for: region, displayFrame: bounds,
            imageSize: ScreenPixelSize(width: image.width, height: image.height)) else { throw MediaFailure.unreadable }
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0,
              pixels.width <= 16384, pixels.height <= 16384 else { throw MediaFailure.tooLarge }
        try MediaTextInput(width: Int(pixels.width), height: Int(pixels.height)).validate()
        guard let piece = image.cropping(to: pixels) else { throw MediaFailure.unreadable }
        let result = try await measurer.geometry(in: piece)
        try Task.checkCancellation()
        let sx = max(CGFloat(image.width) / max(bounds.width, 1), 1)
        let sy = max(CGFloat(image.height) / max(bounds.height, 1), 1)
        guard result.lines.count <= 1024,
              result.lines.allSatisfy({ line in
                  [line.minX, line.minY, line.width, line.height].allSatisfy(\.isFinite) &&
                  line.width > 0 && line.height > 0 && line.minX >= 0 && line.minY >= 0 &&
                  line.maxX <= pixels.width && line.maxY <= pixels.height
              }), result.height.map({ $0.isFinite && $0 > 0 && $0 <= pixels.height }) ?? true
        else { throw MediaFailure.invalidProtocol }
        return .init(lines: result.lines.map { CGRect(x: (pixels.minX + $0.minX) / sx, y: (pixels.minY + $0.minY) / sy,
            width: $0.width / sx, height: $0.height / sy) }, height: result.height.map { $0 / sy })
    }
}
