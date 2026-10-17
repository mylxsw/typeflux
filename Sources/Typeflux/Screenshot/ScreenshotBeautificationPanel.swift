import AppKit
import SwiftUI

@MainActor
final class ScreenshotBeautificationPreview: ObservableObject {
    @Published var settings: ScreenshotBeautification { didSet { refresh() } }
    @Published private(set) var image: CGImage?
    @Published private(set) var failed = false
    private let source: CGImage
    private let scale: CGFloat
    private let originalSize: CGSize
    private let originalScale: CGFloat

    init(source: CGImage, scale: CGFloat, settings: ScreenshotBeautification) {
        // Preview work stays bounded even for scrolling captures. Keep its points-to-pixels ratio.
        let ratio = min(1, 1000 / CGFloat(max(source.width, source.height)))
        if ratio < 1,
           let context = CGContext(data: nil, width: max(1, Int(CGFloat(source.width) * ratio)),
                                   height: max(1, Int(CGFloat(source.height) * ratio)), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: ScreenshotMosaicEffects.colorSpace(of: source),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            self.source = context.makeImage() ?? source
        } else {
            self.source = source
        }
        self.scale = self.source === source ? scale : scale * ratio
        originalSize = CGSize(width: source.width, height: source.height)
        originalScale = scale
        self.settings = settings.normalized
        refresh()
    }

    private func refresh() {
        do {
            if settings.isEnabled {
                _ = try ScreenshotBeautificationRenderer.canvasSize(for: originalSize, scale: originalScale,
                                                                    settings: settings)
            }
            image = try ScreenshotBeautificationRenderer.render(source, scale: scale, settings: settings)
            failed = false
        } catch {
            image = nil
            failed = true
        }
    }
}

/// A sheet keeps the source selection fixed while previewing. Cancel discards the draft settings.
@MainActor
final class ScreenshotBeautificationPanel: NSObject, NSWindowDelegate {
    private(set) var panel: NSPanel?

    func present(source: CGImage, scale: CGFloat, settings: ScreenshotBeautification, over parent: NSWindow,
                 apply: @escaping (ScreenshotBeautification) -> Void) {
        dismiss()
        var draft = settings
        draft.isEnabled = true
        let model = ScreenshotBeautificationPreview(source: source, scale: scale, settings: draft)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 780, height: 590),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L("screenshot.beautify.title")
        panel.level = parent.level
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScreenshotBeautificationView(model: model,
            cancel: { [weak self] in self?.dismiss() }, apply: { [weak self] in
                apply(model.settings.normalized)
                self?.dismiss()
            }))
        self.panel = panel
        parent.beginSheet(panel)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    func dismiss() {
        guard let panel else { return }
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }
}

struct ScreenshotBeautificationView: View {
    @ObservedObject var model: ScreenshotBeautificationPreview
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(L("screenshot.beautify.title"), systemImage: "photo.artframe").font(.headline)
                Spacer()
                Toggle(L("screenshot.beautify.enabled"), isOn: $model.settings.isEnabled).toggleStyle(.switch)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12))
                if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding(20)
                }
                if model.failed { Text(L("screenshot.beautify.failed")).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(L("screenshot.beautify.preview"))
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Text(L("screenshot.beautify.background")).frame(width: 90, alignment: .leading).lineLimit(1)
                    ForEach(ScreenshotBeautification.Background.allCases, id: \.self) { background in
                        let selected = model.settings.background == background
                        Button {
                            model.settings.background = background
                            model.settings.isEnabled = true
                        } label: {
                            swatch(background)
                                .frame(width: 44, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                            lineWidth: selected ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(L("screenshot.beautify.background.\(background.rawValue)"))
                        .accessibilityLabel(L("screenshot.beautify.background.\(background.rawValue)"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
                slider("padding", value: $model.settings.padding, range: 0 ... 160, suffix: "pt")
                slider("radius", value: $model.settings.cornerRadius, range: 0 ... 80, suffix: "pt")
                slider("shadow", value: $model.settings.shadow, range: 0 ... 1, suffix: "%")
            }
            HStack {
                Button(L("screenshot.beautify.reset")) { model.settings = ScreenshotBeautification() }
                Spacer()
                Button(L("screenshot.beautify.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L("screenshot.beautify.apply"), action: apply).keyboardShortcut(.defaultAction)
                    .disabled(model.failed)
            }
        }
        .padding(20)
        .frame(width: 780, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func swatch(_ background: ScreenshotBeautification.Background) -> some View {
        if background == .transparent {
            ZStack {
                Color.gray.opacity(0.15)
                Image(systemName: "checkerboard.rectangle").foregroundStyle(.secondary)
            }
        } else {
            LinearGradient(colors: background.colors.map { Color(cgColor: $0) }, startPoint: .topLeading,
                           endPoint: .bottomTrailing)
        }
    }

    private func slider(_ key: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, suffix: String) -> some View {
        HStack {
            Text(L("screenshot.beautify.\(key)")).frame(width: 90, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { value.wrappedValue }, set: {
                value.wrappedValue = $0
                model.settings.isEnabled = true
            }), in: range)
            .accessibilityLabel(L("screenshot.beautify.\(key)"))
            Text("\(Int((value.wrappedValue * (suffix == "%" ? 100 : 1)).rounded())) \(suffix)")
                .monospacedDigit().frame(width: 60, alignment: .trailing)
        }
    }
}
