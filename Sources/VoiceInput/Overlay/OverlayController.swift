import AppKit
import SwiftUI

final class OverlayController {
    struct PersonaPickerItem: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
    }

    private let appState: AppStateStore
    private var window: NSPanel?

    private let model = OverlayViewModel()
    private var dismissWorkItem: DispatchWorkItem?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    init(appState: AppStateStore) {
        self.appState = appState
        model.onDismissRequested = { [weak self] in
            self?.dismiss(after: 0)
        }
    }

    deinit {
        removeKeyMonitoring()
    }

    func setRecordingActionHandlers(onCancel: (() -> Void)?, onConfirm: (() -> Void)?) {
        model.onCancelRequested = onCancel
        model.onConfirmRequested = onConfirm
    }

    func setPersonaPickerHandlers(
        onMoveUp: (() -> Void)?,
        onMoveDown: (() -> Void)?,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?
    ) {
        model.onPersonaMoveUpRequested = onMoveUp
        model.onPersonaMoveDownRequested = onMoveDown
        model.onPersonaConfirmRequested = onConfirm
        model.onPersonaCancelRequested = onCancel
    }

    func show() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.show() }
            return
        }
        if window == nil {
            let view = OverlayView(model: model)
            let hosting = NSHostingView(rootView: view)
            let metrics = metrics(for: .recordingHold)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: metrics.size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level.statusBar
            panel.backgroundColor = NSColor.clear
            panel.hasShadow = false
            panel.isOpaque = false
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.transient]
            panel.contentView = hosting

            window = panel
        }

        model.presentation = .recordingHold
        model.statusText = "正在聆听"
        model.detailText = ""
        model.processingProgress = 0
        refreshWindow()
    }

    func showLockedRecording() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showLockedRecording() }
            return
        }
        show()
        model.presentation = .recordingLocked
        refreshWindow()
    }

    func updateRecordingPreviewText(_ text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateRecordingPreviewText(text) }
            return
        }

        model.detailText = text
        switch model.presentation {
        case .recordingHold:
            model.presentation = .recordingHoldPreview
        case .recordingLocked:
            model.presentation = .recordingLockedPreview
        case .recordingHoldPreview, .recordingLockedPreview:
            break
        default:
            return
        }
        refreshWindow()
    }

    func showProcessing() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showProcessing() }
            return
        }
        show()
        model.presentation = .processing
        model.statusText = "Thinking"
        model.detailText = ""
        model.processingProgress = 0
        refreshWindow()
    }

    func showFailure(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showFailure(message: message) }
            return
        }
        show()
        model.presentation = .failure
        model.statusText = "处理失败"
        model.detailText = message
        refreshWindow()
    }

    func updateLevel(_ level: Float) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateLevel(level) }
            return
        }
        model.level = level
    }

    func updateStreamingText(_ text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateStreamingText(text) }
            return
        }
        model.presentation = .transcriptPreview
        model.detailText = text
        refreshWindow()
    }

    func showNotice(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showNotice(message: message) }
            return
        }
        dismissWorkItem?.cancel()
        model.presentation = .notice
        model.statusText = "提示"
        model.detailText = message
        refreshWindow()
    }

    func showPersonaPicker(items: [PersonaPickerItem], selectedIndex: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showPersonaPicker(items: items, selectedIndex: selectedIndex) }
            return
        }

        dismissWorkItem?.cancel()
        show()
        model.presentation = .personaPicker
        model.personaItems = items
        model.personaSelectedIndex = max(0, min(selectedIndex, max(0, items.count - 1)))
        model.personaViewportHeight = min(360, CGFloat(max(1, items.count)) * 84)
        model.statusText = "Switch Persona"
        model.detailText = ""
        refreshWindow()
    }

    func updatePersonaPickerSelection(_ index: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updatePersonaPickerSelection(index) }
            return
        }

        guard !model.personaItems.isEmpty else { return }
        model.personaSelectedIndex = max(0, min(index, model.personaItems.count - 1))
        refreshWindow()
    }

    func dismissSoon() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismissSoon() }
            return
        }

        if model.presentation == .processing {
            model.processingProgress = 1
            dismiss(after: 0.18)
        } else if model.presentation == .notice {
            return
        } else {
            dismiss(after: StudioTheme.Durations.overlayDismissDelay)
        }
    }

    func dismiss(after delay: TimeInterval) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismiss(after: delay) }
            return
        }
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
            self?.model.detailText = ""
            self?.model.level = 0
            self?.model.processingProgress = 0
            self?.removeKeyMonitoring()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshWindow() {
        positionWindow()
        window?.orderFrontRegardless()
        updateKeyMonitoring()
    }

    private func positionWindow() {
        guard let screen = NSScreen.main, let window else { return }
        let frame = screen.visibleFrame
        let metrics = metrics(for: model.presentation)
        let x: CGFloat
        let y: CGFloat

        switch metrics.anchor {
        case .center:
            x = frame.midX - metrics.size.width / 2
            y = frame.midY - metrics.size.height / 2
        case .bottom:
            x = frame.midX - metrics.size.width / 2
            y = frame.minY + metrics.offset
        case .top:
            x = frame.midX - metrics.size.width / 2
            y = frame.maxY - metrics.offset - metrics.size.height
        }

        window.setContentSize(metrics.size)
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.ignoresMouseEvents = !metrics.interactive
    }

    private func metrics(for presentation: OverlayViewModel.Presentation) -> OverlayMetrics {
        switch presentation {
        case .recordingHold:
            return OverlayMetrics(size: NSSize(width: 118, height: 72), anchor: .bottom, offset: 24, interactive: false)
        case .recordingHoldPreview:
            return OverlayMetrics(size: NSSize(width: 344, height: 118), anchor: .bottom, offset: 24, interactive: false)
        case .recordingLocked:
            return OverlayMetrics(size: NSSize(width: 158, height: 66), anchor: .bottom, offset: 26, interactive: true)
        case .recordingLockedPreview:
            return OverlayMetrics(size: NSSize(width: 344, height: 124), anchor: .bottom, offset: 24, interactive: true)
        case .processing:
            return OverlayMetrics(size: NSSize(width: 118, height: 72), anchor: .bottom, offset: 24, interactive: false)
        case .transcriptPreview:
            return OverlayMetrics(size: NSSize(width: 344, height: 108), anchor: .top, offset: 84, interactive: false)
        case .notice:
            return OverlayMetrics(size: NSSize(width: 344, height: 108), anchor: .bottom, offset: 80, interactive: true)
        case .failure:
            return OverlayMetrics(size: NSSize(width: 352, height: 132), anchor: .top, offset: 78, interactive: true)
        case .personaPicker:
            let viewportHeight = max(180, model.personaViewportHeight)
            return OverlayMetrics(size: NSSize(width: 456, height: viewportHeight + 132), anchor: .center, offset: 0, interactive: true)
        }
    }

    private func updateKeyMonitoring() {
        if model.presentation == .recordingLocked || model.presentation == .recordingLockedPreview || model.presentation == .personaPicker {
            installKeyMonitoringIfNeeded()
        } else {
            removeKeyMonitoring()
        }
    }

    private func installKeyMonitoringIfNeeded() {
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    private func removeKeyMonitoring() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if model.presentation == .recordingLocked || model.presentation == .recordingLockedPreview {
            if Int(event.keyCode) == 53 {
                model.requestCancel()
            }
            return
        }

        guard model.presentation == .personaPicker else { return }
        switch Int(event.keyCode) {
        case 53:
            model.requestCancel()
        case 125:
            model.requestPersonaMoveDown()
        case 126:
            model.requestPersonaMoveUp()
        case 36, 76:
            model.requestPersonaConfirm()
        default:
            return
        }
    }
}

private struct OverlayMetrics {
    enum Anchor {
        case top
        case bottom
        case center
    }

    let size: NSSize
    let anchor: Anchor
    let offset: CGFloat
    let interactive: Bool
}

final class OverlayViewModel: ObservableObject {
    enum Presentation {
        case recordingHold
        case recordingHoldPreview
        case recordingLocked
        case recordingLockedPreview
        case processing
        case transcriptPreview
        case notice
        case failure
        case personaPicker
    }

    @Published var presentation: Presentation = .recordingHold
    @Published var statusText: String = ""
    @Published var detailText: String = ""
    @Published var level: Float = 0
    @Published var processingProgress: CGFloat = 0
    @Published var personaItems: [OverlayController.PersonaPickerItem] = []
    @Published var personaSelectedIndex: Int = 0
    @Published var personaViewportHeight: CGFloat = 240
    var onDismissRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?
    var onConfirmRequested: (() -> Void)?
    var onPersonaMoveUpRequested: (() -> Void)?
    var onPersonaMoveDownRequested: (() -> Void)?
    var onPersonaConfirmRequested: (() -> Void)?
    var onPersonaCancelRequested: (() -> Void)?

    func requestDismiss() {
        onDismissRequested?()
    }

    func requestCancel() {
        onCancelRequested?()
    }

    func requestConfirm() {
        onConfirmRequested?()
    }

    func requestPersonaMoveUp() {
        onPersonaMoveUpRequested?()
    }

    func requestPersonaMoveDown() {
        onPersonaMoveDownRequested?()
    }

    func requestPersonaConfirm() {
        onPersonaConfirmRequested?()
    }

    func requestPersonaCancel() {
        onPersonaCancelRequested?()
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayViewModel

    var body: some View {
        Group {
            switch model.presentation {
            case .recordingHold:
                recordingCapsule
            case .recordingHoldPreview:
                recordingPreviewCard(showControls: false)
            case .recordingLocked:
                lockedRecordingCapsule
            case .recordingLockedPreview:
                recordingPreviewCard(showControls: true)
            case .processing:
                processingCapsule
            case .transcriptPreview:
                previewCard
            case .notice:
                noticeToast
            case .failure:
                failureCard
            case .personaPicker:
                personaPickerCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
        .padding(containerPadding)
    }

    private var contentAlignment: Alignment {
        switch model.presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview, .processing, .notice:
            return .bottom
        case .transcriptPreview, .failure:
            return .top
        case .personaPicker:
            return .center
        }
    }

    private var containerPadding: EdgeInsets {
        switch model.presentation {
        case .recordingHold, .processing:
            return EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
        case .recordingHoldPreview:
            return EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
        case .recordingLocked:
            return EdgeInsets(top: 15, leading: 14, bottom: 15, trailing: 14)
        case .recordingLockedPreview:
            return EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
        case .transcriptPreview, .notice, .failure:
            return EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        case .personaPicker:
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        }
    }

    private var recordingCapsule: some View {
        OverlayCapsule {
            LevelWaveform(level: model.level, activeColor: Color.white.opacity(0.95))
                .frame(width: 38, height: 14)
        }
    }

    private var processingCapsule: some View {
        ThinkingProgressCapsule(
            title: model.statusText.isEmpty ? "Thinking" : model.statusText,
            progress: model.processingProgress
        )
    }

    private var lockedRecordingCapsule: some View {
        LockedRecordingCapsule(
            level: model.level,
            onCancel: model.requestCancel,
            onConfirm: model.requestConfirm
        )
    }

    private func recordingPreviewCard(showControls: Bool) -> some View {
        OverlayCompactToast(width: 312) {
            VStack(alignment: .leading, spacing: 10) {
                if showControls {
                    HStack(spacing: 8) {
                        Button(action: model.requestCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.96))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)

                        LevelWaveform(level: model.level, activeColor: Color.white.opacity(0.95))
                            .frame(width: 38, height: 14)

                        Spacer(minLength: 0)

                        Button(action: model.requestConfirm) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.9))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.white.opacity(0.98)))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    LevelWaveform(level: model.level, activeColor: Color.white.opacity(0.95))
                        .frame(width: 38, height: 14)
                }

                Text("“\(model.detailText)”")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .lineLimit(2)
            }
        }
    }

    private var previewCard: some View {
        OverlayCompactToast(width: 312) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.43, green: 0.56, blue: 1.0))

                Text("“\(model.detailText)”")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
        }
    }

    private var failureCard: some View {
        OverlayCard(width: 320) {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader(icon: "exclamationmark.circle", accent: Color(red: 1.0, green: 0.42, blue: 0.08), title: model.statusText, dismissible: true)

                Text(model.detailText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var noticeToast: some View {
        OverlayCompactToast(width: 312) {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader(
                    icon: "info.circle",
                    accent: Color(red: 0.43, green: 0.56, blue: 1.0),
                    title: model.statusText,
                    dismissible: true,
                    titleSize: 13.5
                )

                Text(model.detailText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(2)
            }
        }
    }

    private var personaPickerCard: some View {
        OverlayCard(width: 420) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.statusText)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.96))

                        Text("Use Up and Down to choose, then press Return to confirm.")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }

                    Spacer(minLength: 0)

                    Button(action: model.requestPersonaCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(model.personaItems.enumerated()), id: \.element.id) { index, item in
                            personaPickerRow(item: item, isSelected: index == model.personaSelectedIndex)
                        }
                    }
                    .padding(2)
                }
                .frame(height: model.personaViewportHeight)
            }
        }
    }

    private func personaPickerRow(item: OverlayController.PersonaPickerItem, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color(red: 0.43, green: 0.56, blue: 1.0).opacity(0.24) : Color.white.opacity(0.06))
                .frame(width: 38, height: 38)
                .overlay(
                    Text(String(item.title.prefix(2)).uppercased())
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(isSelected ? Color(red: 0.68, green: 0.78, blue: 1.0) : Color.white.opacity(0.7))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.96))
                Text(item.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.64))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.68, green: 0.78, blue: 1.0))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? Color(red: 0.43, green: 0.56, blue: 1.0).opacity(0.72) : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func cardHeader(
        icon: String,
        accent: Color,
        title: String,
        dismissible: Bool,
        titleSize: CGFloat = 16.5
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)

            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))

            Spacer(minLength: 0)

            if dismissible {
                Button(action: model.requestDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "xmark")
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }
}

private struct LockedRecordingCapsule: View {
    let level: Float
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            roundIconButton(systemName: "xmark", action: onCancel)

            LevelWaveform(level: level, activeColor: Color.white.opacity(0.95))
                .frame(width: 38, height: 14)

            roundIconButton(systemName: "checkmark", action: onConfirm, inverted: true)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5.5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.9))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1.2)
                )
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 12)
    }

    private func roundIconButton(systemName: String, action: @escaping () -> Void, inverted: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(inverted ? Color.black.opacity(0.9) : Color.white.opacity(0.96))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(inverted ? Color.white.opacity(0.98) : Color.white.opacity(0.22))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ThinkingProgressCapsule: View {
    let title: String
    let progress: CGFloat
    @State private var displayProgress: CGFloat = 0

    var body: some View {
        let capsuleShape = Capsule(style: .continuous)

        ZStack {
            capsuleShape
                .fill(Color.black.opacity(0.9))

            GeometryReader { geo in
                let width = max(0, geo.size.width)

                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: max(0, width * displayProgress))
                }
            }
            .mask(capsuleShape)

            capsuleShape
                .stroke(Color.white.opacity(0.22), lineWidth: 1.2)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, 12)
        }
        .frame(width: 78, height: 35)
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 12)
        .onAppear {
            advanceProgress()
        }
        .onChange(of: progress) { newValue in
            if newValue >= 1 {
                withAnimation(.easeOut(duration: 0.16)) {
                    displayProgress = 1
                }
            } else if newValue <= 0.0001 {
                displayProgress = 0
                advanceProgress()
            }
        }
    }

    private func advanceProgress() {
        guard progress <= 0.0001 else { return }

        withAnimation(.linear(duration: 0.9)) {
            displayProgress = 0.68
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard progress < 0.69, displayProgress < 0.69 else { return }
            withAnimation(.easeOut(duration: 1.4)) {
                displayProgress = 0.9
            }
        }
    }
}

private struct OverlayCapsule<Content: View>: View {
    let horizontalPadding: CGFloat
    @ViewBuilder var content: Content

    init(horizontalPadding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 10.5)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.88))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.22), lineWidth: 1.2)
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 12)
    }
}

private struct OverlayCard<Content: View>: View {
    let width: CGFloat
    let compact: Bool
    @ViewBuilder var content: Content

    init(width: CGFloat, compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.width = width
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, compact ? 16 : 23)
            .padding(.vertical, compact ? 12 : 21)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.11, blue: 0.11).opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.32), radius: 26, x: 0, y: 16)
    }
}

private struct OverlayCompactToast<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content

    init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.11, blue: 0.11).opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 12)
    }
}

private struct OverlayButton: View {
    let title: String
    let compact: Bool

    init(title: String, compact: Bool = false) {
        self.title = title
        self.compact = compact
    }

    var body: some View {
        Text(title)
            .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.96))
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical, compact ? 8.5 : 10.5)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.14))
            )
    }
}

private struct LevelWaveform: View {
    let level: Float
    let activeColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2.2) {
            ForEach(0..<9, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(activeColor)
                    .frame(width: 2.3, height: barHeight(for: index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalizedLevel = CGFloat(max(0.08, min(1.0, level)))
        let profile: [CGFloat] = [0.34, 0.52, 0.72, 0.9, 1.0, 0.86, 0.7, 0.5, 0.32]
        return 4.5 + (10.8 * normalizedLevel * profile[index])
    }
}
