import AppKit
import SwiftUI

protocol LocalModelDownloadAlertPresenting {
    @MainActor
    func showDownloadingAlert(model: LocalSTTModel, progress: Double)
}

final class SystemLocalModelDownloadAlertPresenter: NSObject, LocalModelDownloadAlertPresenting, NSWindowDelegate,
    @unchecked Sendable {
    private var alertWindow: NSPanel?
    private var alertViewModel: LocalModelDownloadAlertViewModel?
    private var progressObserver: NSObjectProtocol?
    private var progressTimer: Timer?

    @MainActor
    func showDownloadingAlert(model: LocalSTTModel, progress: Double) {
        if let alertWindow, let alertViewModel {
            alertViewModel.progress = progress
            alertWindow.orderFront(nil)
            return
        }

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 190),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self

        let viewModel = LocalModelDownloadAlertViewModel(progress: progress)
        let contentView = LocalModelDownloadAlertContentView(
            viewModel: viewModel,
            title: L("workflow.localModelDownloadingAlert.title"),
            message: L("workflow.localModelDownloadingAlert.message", model.displayName)
        ) { [weak self] in
            self?.closeAlert()
        }
        window.contentViewController = NSHostingController(rootView: contentView)

        progressObserver = NotificationCenter.default.addObserver(
            forName: .localModelDownloadProgressDidChange,
            object: nil,
            queue: .main
        ) { [weak self, weak viewModel] _ in
            self?.applyProgressStatus(
                LocalModelDownloadProgressCenter.shared.status,
                model: model,
                viewModel: viewModel
            )
        }

        alertWindow = window
        alertViewModel = viewModel
        startProgressTimer(model: model, viewModel: viewModel)
        centerAlertWindow(window)
        window.orderFront(nil)
    }

    @MainActor
    private func closeAlert() {
        alertWindow?.close()
        cleanupAlert()
    }

    @MainActor
    func windowWillClose(_: Notification) {
        cleanupAlert()
    }

    @MainActor
    private func cleanupAlert() {
        if let progressObserver {
            NotificationCenter.default.removeObserver(progressObserver)
            self.progressObserver = nil
        }
        progressTimer?.invalidate()
        progressTimer = nil
        alertWindow?.delegate = nil
        alertWindow = nil
        alertViewModel = nil
    }

    @MainActor
    private func startProgressTimer(model: LocalSTTModel, viewModel: LocalModelDownloadAlertViewModel) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak viewModel] _ in
            self?.applyProgressStatus(
                LocalModelDownloadProgressCenter.shared.status,
                model: model,
                viewModel: viewModel
            )
        }
    }

    private func applyProgressStatus(
        _ status: LocalModelDownloadProgressStatus,
        model: LocalSTTModel,
        viewModel: LocalModelDownloadAlertViewModel?
    ) {
        switch status {
        case let .downloading(currentModel, currentProgress) where currentModel == model:
            Task { @MainActor in
                viewModel?.failureMessage = nil
                viewModel?.progress = currentProgress
            }
        case let .failed(currentModel, message) where currentModel == model:
            Task { @MainActor in
                viewModel?.failureMessage = message
            }
        case .idle:
            Task { @MainActor [weak self] in
                self?.closeAlert()
            }
        default:
            break
        }
    }

    @MainActor
    private func centerAlertWindow(_ window: NSWindow) {
        let targetScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visibleFrame = targetScreen?.visibleFrame else {
            window.center()
            return
        }

        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        window.setFrameOrigin(origin)
    }
}

@MainActor
private final class LocalModelDownloadAlertViewModel: ObservableObject {
    @Published var progress: Double
    @Published var failureMessage: String?

    init(progress: Double) {
        self.progress = progress
    }
}

private struct LocalModelDownloadAlertContentView: View {
    @ObservedObject var viewModel: LocalModelDownloadAlertViewModel
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                progressSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)

            Divider()

            HStack {
                Spacer()
                Button(L("common.ok"), action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(TypefluxColor.accent.color)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.failureMessage == nil ? title : L("workflow.localModelDownloadingAlert.failedTitle"))
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(viewModel.failureMessage == nil ? message : L(
                    "workflow.localModelDownloadingAlert.failedMessage",
                    viewModel.failureMessage ?? ""
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ProgressView(value: normalizedProgress)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
            Text(progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var normalizedProgress: Double {
        min(max(viewModel.progress, 0), 1)
    }

    private var progressText: String {
        if viewModel.failureMessage != nil {
            return L("workflow.localModelDownloadingAlert.failedProgress")
        }
        let percent = Int((normalizedProgress * 100).rounded())
        return L("workflow.localModelDownloadingAlert.progress", percent)
    }
}
