import AppKit
import SwiftUI

/// The sensitive information panel beside the region: what was found, a tick to cover each
/// one with a mosaic, and "Cover all". Nothing is covered until the user asks.
struct ScreenshotSensitiveInfoPanel: View {
    struct State: Equatable {
        struct Row: Equatable, Identifiable {
            var id: UUID
            var kind: ScreenshotSensitiveFinding.Kind
            /// The found text with its middle hidden.
            var text: String
            var applied: Bool
        }

        var rows: [Row]
        var failed = false

        var allApplied: Bool { rows.allSatisfy(\.applied) }
    }

    enum Action: Equatable {
        case toggle(UUID)
        case applyAll
        case close
    }

    static let width: CGFloat = 248
    static let maximumListHeight: CGFloat = 220

    let state: State
    let perform: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye.trianglebadge.exclamationmark").foregroundStyle(AskTheme.accent)
                Text(L("screenshot.sensitive.title")).font(.system(size: 13, weight: .semibold))
                if !state.failed { Text("\(state.rows.count)").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Button { perform(.close) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("screenshot.sensitive.close"))
            }
            Text(L(state.failed ? "screenshot.sensitive.failed" : "screenshot.sensitive.hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(state.rows) { row in rowView(row) }
                }
            }
            .scrollIndicators(.never)
            .frame(height: min(CGFloat(state.rows.count) * 30, Self.maximumListHeight))
            Button { perform(.applyAll) } label: {
                Text(L("screenshot.sensitive.applyAll")).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(state.allApplied ? Color.secondary : Color.white)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(state.allApplied ? AskTheme.hoverFill : AskTheme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.allApplied)
            if !state.failed {
                Text(L("screenshot.sensitive.footnote")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .screenshotSurface(corner: 12)
    }

    private func rowView(_ row: State.Row) -> some View {
        Button { perform(.toggle(row.id)) } label: {
            HStack(spacing: 8) {
                Image(systemName: row.applied ? "checkmark.square.fill" : "square")
                    .foregroundStyle(row.applied ? AskTheme.accent : Color.secondary)
                Text(row.kind.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(row.text).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(row.applied ? L("screenshot.sensitive.covered") : "")
    }
}

/// Runs the scan for one editor and keeps its panel: the overlay and the long image editor
/// each own one, give it their annotations and say where the region is.
@MainActor
final class ScreenshotSensitiveInfoController {
    private(set) var suggestions = ScreenshotRedactionSuggestions()
    private(set) var host: NSHostingView<AnyView>?
    /// What the panel was last built from, so pointer moves do not rebuild it.
    private var shown: (state: ScreenshotSensitiveInfoPanel.State, crop: CGRect?)?
    private let scanner: (any ScreenshotSensitiveInfoScanning)?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var retired = false
    /// The panel's content changed; the editor lays it out again.
    var onChange: (() -> Void)?
    var annotations: () -> [ScreenshotAnnotation] = { [] }
    /// Adds mosaics over these rectangles as one undo step and returns their ids.
    var addMosaics: ([CGRect]) -> [UUID] = { _ in [] }
    var removeAnnotations: (Set<UUID>) -> Void = { _ in }

    static let gap: CGFloat = 12

    init(scanner: (any ScreenshotSensitiveInfoScanning)?) {
        self.scanner = scanner
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }
    deinit { task?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }

    /// Looks for sensitive text once, in the background.
    func scan(_ image: CGImage, scale: CGFloat) {
        guard !retired, let scanner, suggestions.status == .idle else { return }
        suggestions.beginScan()
        let size = CGSize(width: image.width, height: image.height)
        task = Task { [weak self] in
            do {
                let findings = try await scanner.scan(image)
                guard !Task.isCancelled, let self, !self.retired else { return }
                self.suggestions.finishScan(findings, imageSize: size, scale: scale)
                self.onChange?()
            } catch {
                guard !Task.isCancelled, let self, !self.retired else { return }
                self.suggestions.failScan(); self.onChange?()
            }
        }
    }

    /// Something was found, so the panel has something to show, even after it was closed.
    var hasFindings: Bool {
        suggestions.status == .done && !suggestions.items.isEmpty
    }

    var isPanelShown: Bool {
        (hasFindings || suggestions.status == .failed) && !suggestions.isDismissed
    }

    /// The More menu's "Sensitive information": shows the panel again, or puts it away.
    func setPanelShown(_ shown: Bool) {
        suggestions.isDismissed = !shown
        onChange?()
    }

    /// Waits for the scan, for tests.
    func waitForScan() async {
        await task?.value
    }

    func cancel() {
        retired = true
        task?.cancel()
        task = nil
        suggestions = ScreenshotRedactionSuggestions()
        host?.removeFromSuperview(); host = nil; shown = nil
        onChange?()
    }

    func perform(_ action: ScreenshotSensitiveInfoPanel.Action, crop: CGRect?) {
        let current = annotations()
        let change: ScreenshotRedactionSuggestions.Change
        switch action {
        case let .toggle(id): change = suggestions.toggle(id, in: current)
        case .applyAll: change = suggestions.applyAll(in: crop, annotations: current)
        case .close:
            suggestions.isDismissed = true
            change = .none
        }
        switch change {
        case let .add(items): suggestions.record(addMosaics(items.map(\.rect)), for: items)
        case let .remove(ids): removeAnnotations(ids)
        case .none: break
        }
        onChange?()
    }

    /// Shows, updates or hides the panel in `view`.
    /// - Parameter frame: where the panel goes, given its size.
    func layout(in view: NSView, crop: CGRect?, hidden: Bool = false, frame: (CGSize) -> CGRect) {
        guard !hidden, let state = suggestions.panelState(crop: crop, annotations: annotations()) else {
            host?.isHidden = true
            shown = nil
            return
        }
        // Unchanged: only follow the editor's layout, without measuring the panel again.
        if let host, let shown, shown.state == state, shown.crop == crop, !host.isHidden {
            host.frame = frame(host.frame.size)
            return
        }
        shown = (state, crop)
        let content = AnyView(ScreenshotSensitiveInfoPanel(state: state) { [weak self] action in
            self?.perform(action, crop: crop)
        }.screenshotAppearance())
        let host: NSHostingView<AnyView>
        if let existing = self.host {
            host = existing
            host.rootView = content
        } else {
            host = NSHostingView(rootView: content)
            view.addSubview(host)
            self.host = host
        }
        host.isHidden = false
        host.frame = frame(host.fittingSize)
    }

    /// Beside the region: on its right, else its left, else inside its top-right corner;
    /// level with its top and kept on the display.
    static func panelFrame(beside crop: CGRect, size: CGSize, in bounds: CGRect) -> CGRect {
        var origin: CGPoint
        if crop.maxX + gap + size.width <= bounds.maxX {
            origin = CGPoint(x: crop.maxX + gap, y: crop.minY)
        } else if crop.minX - gap - size.width >= bounds.minX {
            origin = CGPoint(x: crop.minX - gap - size.width, y: crop.minY)
        } else {
            origin = CGPoint(x: max(bounds.minX, crop.maxX - gap - size.width), y: crop.minY + gap)
        }
        origin.y = min(max(origin.y, bounds.minY), max(bounds.maxY - size.height, bounds.minY))
        return CGRect(origin: origin, size: size)
    }
}
