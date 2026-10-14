import AppKit

/// Owns independent recording results while allowing only one live capture at a time.
@MainActor
final class ScreenRecordingSessionController {
    struct Session {
        let model: ScreenRecordingCoordinator
        let window: ScreenRecordingWindowController
        let recoverySource: URL?
    }

    private(set) var sessions: [Session] = []
    var isOtherCaptureActive: () -> Bool = { false }
    private let makeModel: () -> ScreenRecordingCoordinator
    private let makeWindow: () -> ScreenRecordingWindowController
    private let toast: ScreenRecordingToastController

    init(settings: SettingsStore,
         makeWindow: (() -> ScreenRecordingWindowController)? = nil,
         makeModel: @escaping () -> ScreenRecordingCoordinator) {
        let toast = ScreenRecordingToastController(settings: settings)
        self.toast = toast
        self.makeModel = makeModel
        self.makeWindow = makeWindow ?? { ScreenRecordingWindowController(settings: settings, toast: toast) }
    }

    var isCaptureActive: Bool {
        sessions.contains { $0.model.isCaptureActive }
    }

    var isBusy: Bool {
        sessions.contains { $0.model.isBusy }
    }

    func show(format: ScreenRecordingFormat? = nil, region: ScreenRecordingTarget? = nil) {
        if let active = sessions.first(where: { $0.model.isCaptureActive }) {
            active.model.show()
            return
        }
        guard !isOtherCaptureActive() else { return }
        let session = retain(makeModel())
        session.model.show(format: format, region: region)
    }

    private func retain(_ model: ScreenRecordingCoordinator, recoverySource: URL? = nil) -> Session {
        let window = makeWindow()
        let session = Session(model: model, window: window, recoverySource: recoverySource)
        model.isOtherCaptureActive = { [weak self] in self?.isOtherCaptureActive() ?? false }
        model.present = { [weak window] in window?.show($0) }
        model.dismiss = { [weak self, weak model, weak window] in
            window?.hide()
            guard let model, model.state == .idle else { return }
            self?.sessions.removeAll { $0.model === model }
        }
        model.updateIndicator = { [weak window] in window?.indicator($0) }
        model.showBorder = { [weak window] in window?.outline($0) }
        sessions.append(session)
        return session
    }

    /// Only offered at launch or after discarding a recovery item. Open editors are
    /// already owned here and must never be offered as abandoned recordings.
    func offerRecovery() {
        let model = makeModel()
        let openSources = Set(sessions.compactMap { $0.model.sourceURL ?? $0.recoverySource })
        guard let source = model.findRecoverableSources().first(where: { !openSources.contains($0) }) else { return }
        toast.showRecovery(source, open: { [weak self] in
            self?.recover(source)
        }, discard: { [weak self] in
            model.discardRecovered(source)
            self?.offerRecovery()
        })
    }

    func recover(_ source: URL) {
        if let existing = sessions.first(where: { ($0.model.sourceURL ?? $0.recoverySource) == source }) {
            existing.window.show(existing.model)
            return
        }
        let session = retain(makeModel(), recoverySource: source)
        session.model.recover(source)
        session.window.show(session.model)
    }

    func prepareForTermination() async {
        // Cancellation can remove sessions while this awaits; keep a stable snapshot.
        for session in sessions {
            await session.model.prepareForTermination()
        }
    }
}
