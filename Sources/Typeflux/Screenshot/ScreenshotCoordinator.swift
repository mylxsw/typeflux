import CoreGraphics
import Foundation

/// Runs one screenshot at a time, from the shortcut, the launcher or the menu bar.
///
/// `idle → capturing → selecting → editing → finishing → idle`. Every way out
/// (esc, a failure, a finished copy or save) goes through `teardown()`, which closes
/// the overlay and drops the frozen images.
@MainActor
final class ScreenshotCoordinator {
    enum State: Equatable {
        case idle
        /// Freezing the displays.
        case capturing
        /// Framing: nothing chosen yet.
        case selecting
        /// A region is chosen and can still be adjusted and marked up.
        case editing
        /// The overlay has closed; the image is being encoded and delivered.
        case finishing
    }

    typealias Encoder = @Sendable (CGImage, CGFloat) throws -> Data
    typealias Renderer = (ScreenSnapshot.Display, CGRect, [ScreenshotAnnotation]) throws -> CGImage

    private(set) var state: State = .idle
    /// The frozen displays, held only while the overlay shows.
    private(set) var snapshot: ScreenSnapshot?
    /// The capture or delivery in flight, so tests can wait for it.
    private(set) var pendingTask: Task<Void, Never>?

    private let capture: any ScreenCapturing
    private let permission: any ScreenCapturePermissionProviding
    private let overlay: any ScreenshotOverlayPresenting
    private let permissionGuide: any ScreenshotPermissionGuidePresenting
    private let toast: any ScreenshotToastPresenting
    private let output: any ScreenshotOutputting
    private let saveDirectory: () -> URL
    private let now: () -> Date
    private let relaunch: () -> Void
    private let encode: Encoder
    private let render: Renderer
    /// Bumped by every teardown, so a capture or delivery from an earlier session is ignored.
    private var session = 0

    init(capture: any ScreenCapturing,
         permission: any ScreenCapturePermissionProviding,
         overlay: any ScreenshotOverlayPresenting,
         permissionGuide: any ScreenshotPermissionGuidePresenting,
         toast: any ScreenshotToastPresenting,
         output: any ScreenshotOutputting,
         saveDirectory: @escaping () -> URL,
         now: @escaping () -> Date = Date.init,
         relaunch: @escaping () -> Void = {},
         encode: @escaping Encoder = { try ScreenshotImageExporter.png($0, scale: $1) },
         render: @escaping Renderer = { try ScreenshotRenderer.render($0, crop: $1, annotations: $2) }) {
        self.capture = capture
        self.permission = permission
        self.overlay = overlay
        self.permissionGuide = permissionGuide
        self.toast = toast
        self.output = output
        self.saveDirectory = saveDirectory
        self.now = now
        self.relaunch = relaunch
        self.encode = encode
        self.render = render
    }

    /// Starts a screenshot. While framing, starting again selects the whole display;
    /// while capturing or finishing, it is ignored with a notice.
    func start(mode: ScreenshotMode = .region) {
        switch state {
        case .idle:
            break
        case .selecting, .editing:
            overlay.selectFullScreen()
            state = .editing
            return
        case .capturing, .finishing:
            toast.show(.busy)
            return
        }
        guard permission.isGranted else {
            presentPermissionGuide(mode: mode)
            return
        }
        permissionGuide.dismiss()
        state = .capturing
        let session = session
        let capture = capture
        pendingTask = Task { [weak self] in
            let result: Result<ScreenSnapshot, Error>
            do {
                result = try await .success(capture.snapshot(ScreenCaptureRequest()))
            } catch {
                result = .failure(error)
            }
            self?.didCapture(result, mode: mode, session: session)
        }
    }

    /// Esc, or anything else that abandons the screenshot.
    func cancel() {
        teardown()
    }

    func handle(_ event: ScreenshotOverlayEvent) {
        switch event {
        case .committed:
            if state == .selecting { state = .editing }
        case .cancelled:
            teardown()
        case let .colorPicked(hex):
            guard state == .selecting || state == .editing else { return }
            output.copy(text: hex)
            toast.show(.colorCopied(hex))
        case let .finish(action, displayID, rect, annotations):
            finish(action, displayID: displayID, rect: rect, annotations: annotations)
        }
    }

    // MARK: Permission

    /// Asks the system once (its prompt also lists Typeflux in System Settings) and
    /// shows the guide every time access is missing.
    private func presentPermissionGuide(mode: ScreenshotMode) {
        permission.requestOnce()
        permissionGuide.show(actions: ScreenshotPermissionGuideActions(
            openSettings: { [weak self] in self?.permission.openSystemSettings() },
            recheck: { [weak self] in self?.recheckPermission(mode: mode) ?? false },
            restart: { [weak self] in self?.relaunch() },
            later: { [weak self] in self?.permissionGuide.dismiss() }
        ))
    }

    /// "Check again" in the guide: starts the screenshot once access is there.
    func recheckPermission(mode: ScreenshotMode = .region) -> Bool {
        guard permission.isGranted else { return false }
        permissionGuide.dismiss()
        start(mode: mode)
        return true
    }

    // MARK: Session

    private func didCapture(_ result: Result<ScreenSnapshot, Error>, mode: ScreenshotMode, session: Int) {
        // Esc during the capture ends the session; its late result is dropped.
        guard session == self.session, state == .capturing else { return }
        switch result {
        case let .success(snapshot):
            self.snapshot = snapshot
            state = .selecting
            overlay.present(snapshot) { [weak self] event in self?.handle(event) }
            if mode == .fullScreen {
                overlay.selectFullScreen()
                state = .editing
            }
        case let .failure(error):
            teardown()
            if (error as? ScreenCaptureError) == .permissionDenied {
                presentPermissionGuide(mode: mode)
            } else {
                toast.show(.failed)
            }
        }
    }

    private func finish(_ action: ScreenshotOutputAction, displayID: CGDirectDisplayID, rect: CGRect,
                        annotations: [ScreenshotAnnotation]) {
        guard state == .selecting || state == .editing, let display = snapshot?.display(id: displayID) else { return }
        let image: CGImage
        do {
            // Only the rendered image leaves the overlay, so nothing under a mosaic is ever copied or saved.
            image = try render(display, rect, annotations)
        } catch {
            teardown()
            toast.show(.failed)
            return
        }
        // The overlay closes first, so the user is back at once; encoding runs off the main thread.
        state = .finishing
        overlay.dismiss()
        snapshot = nil
        let scale = display.scale, session = session, encode = encode
        pendingTask = Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { try? encode(image, scale) }.value
            self?.deliver(png, action: action, session: session)
        }
    }

    private func deliver(_ png: Data?, action: ScreenshotOutputAction, session: Int) {
        guard session == self.session, state == .finishing else { return }
        defer { teardown() }
        guard let png else {
            toast.show(.failed)
            return
        }
        switch action {
        case .copy:
            toast.show(output.copy(png) ? .copied : .failed)
        case .save:
            do {
                let url = try output.save(png, in: saveDirectory(), date: now())
                toast.show(.saved(url))
            } catch {
                // Never lose the shot: it goes to the clipboard instead, with the reason.
                toast.show(output.copy(png) ? .savedAsCopy(reason: error.localizedDescription) : .failed)
            }
        }
    }

    private func teardown() {
        overlay.dismiss()
        snapshot = nil
        state = .idle
        session += 1
    }
}
