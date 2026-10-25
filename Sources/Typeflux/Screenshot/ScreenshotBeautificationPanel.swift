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
        let ratio = min(1, 1600 / CGFloat(max(source.width, source.height)))
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
        let availableSize = parent.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size
            ?? ScreenshotBeautificationView.size
        let panelSize = ScreenshotBeautificationView.size(for: availableSize)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: panelSize),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L("screenshot.beautify.title")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = parent.level
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScreenshotBeautificationView(model: model, panelSize: panelSize,
            cancel: { [weak self] in self?.dismiss() }, apply: { [weak self] in
                apply(model.settings.normalized)
                self?.dismiss()
            }).screenshotAppearance())
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
    @Environment(\.interfaceStyle) private var interfaceStyle
    private var textColor: Color { interfaceStyle == .classic ? .white : StudioTheme.textPrimary }

    static let size = CGSize(width: 960, height: 720)
    static func size(for availableSize: CGSize) -> CGSize {
        CGSize(width: min(size.width, max(760, availableSize.width - 48)),
               height: min(size.height, max(560, availableSize.height - 72)))
    }
    @ObservedObject var model: ScreenshotBeautificationPreview
    var panelSize = Self.size
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    palette
                        .frame(width: 236, alignment: .leading)
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                    VStack(spacing: 13) {
                        slider("padding", symbol: "arrow.up.left.and.arrow.down.right",
                               value: \.padding, range: 0 ... 160, suffix: "pt")
                        slider("radius", symbol: "app", value: \.cornerRadius,
                               range: 0 ... 80, suffix: "pt")
                        slider("shadow", symbol: "square.3.layers.3d", value: \.shadow,
                               range: 0 ... 1, suffix: "%")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.vertical, 16)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                actions.padding(.horizontal, 20).padding(.vertical, 12)
            }
            .screenshotSurface(corner: 16, elevation: nil, classicFill: Color(white: 0.13))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.09)))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background {
            if interfaceStyle.usesGlass { AskWindowBackdrop() }
            else { Color(white: 0.075) }
        }
        .foregroundStyle(textColor.opacity(0.9))
        .preferredColorScheme(interfaceStyle == .classic ? .dark : nil)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(textColor.opacity(0.6))
            Text(L("screenshot.beautify.title")).font(.system(size: 14, weight: .semibold))
            Spacer()
            Toggle(L("screenshot.beautify.enabled"), isOn: $model.settings.isEnabled)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11)).foregroundStyle(textColor.opacity(0.6))
                .accessibilityLabel(L("screenshot.beautify.enabled"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var preview: some View {
        ZStack {
            if let image = model.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .background {
                        ScreenshotTransparencyGrid()
                            .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            }
            if model.failed {
                Label(L("screenshot.beautify.failed"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("screenshot.beautify.preview"))
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("screenshot.beautify.background")).foregroundStyle(textColor.opacity(0.6))
                        .font(.system(size: 11, weight: .medium))
                    Text(L("screenshot.beautify.background.\(model.settings.background.rawValue)"))
                        .foregroundStyle(textColor.opacity(0.9)).font(.system(size: 10))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach([ScreenshotBeautification.Background.transparent, .white, .charcoal], id: \.self) {
                        swatchButton($0, size: 26, radius: 13)
                    }
                }
            }
            let wallpapers = ScreenshotBeautification.Background.availableCases.filter { $0.wallpaperURL != nil }
            let colors: [ScreenshotBeautification.Background] = [
                .sky, .mint, .sunset, .lavender, .ocean, .peach, .graphite
            ] + wallpapers
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 7), count: 5),
                      alignment: .leading, spacing: 7) {
                ForEach(colors, id: \.self) { swatchButton($0, size: 32, radius: 7) }
            }
        }
    }

    private func swatchButton(_ background: ScreenshotBeautification.Background,
                              size: CGFloat, radius: CGFloat) -> some View {
        let selected = model.settings.background == background
        return Button {
            var settings = model.settings
            settings.background = background
            settings.isEnabled = true
            model.settings = settings
        } label: {
            swatch(background)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.2)))
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(background == .white || background == .mint ? .black : .white)
                    }
                }
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: radius + 3)
                    .strokeBorder(selected ? .white.opacity(0.9) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(L("screenshot.beautify.background.\(background.rawValue)"))
        .accessibilityLabel(L("screenshot.beautify.background.\(background.rawValue)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                model.settings = ScreenshotBeautification()
            } label: {
                Label(L("screenshot.beautify.reset"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.plain).foregroundStyle(textColor.opacity(0.6))
            .padding(.vertical, 6).contentShape(Rectangle())
            Spacer()
            Button(L("screenshot.beautify.cancel"), action: cancel)
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
                .keyboardShortcut(.cancelAction)
            Button(action: apply) {
                Label(L("screenshot.beautify.apply"), systemImage: "checkmark")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .foregroundStyle(Color(white: 0.1))
                    .background(.white.opacity(model.failed ? 0.3 : 0.95),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(model.failed)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func swatch(_ background: ScreenshotBeautification.Background) -> some View {
        if background == .transparent {
            ScreenshotTransparencyGrid()
        } else if let image = ScreenshotBeautificationRenderer.wallpaper(background, maxDimension: 128) {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            LinearGradient(colors: background.colors.map { Color(cgColor: $0) }, startPoint: .topLeading,
                           endPoint: .bottomTrailing)
        }
    }

    private func slider(_ key: String, symbol: String, value: WritableKeyPath<ScreenshotBeautification, CGFloat>,
                        range: ClosedRange<CGFloat>, suffix: String) -> some View {
        let current = model.settings[keyPath: value]
        return HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 14).foregroundStyle(textColor.opacity(0.4))
                .accessibilityHidden(true)
            Text(L("screenshot.beautify.\(key)"))
                .frame(width: 64, alignment: .leading).lineLimit(1)
                .foregroundStyle(textColor.opacity(0.75))
            Slider(value: Binding(get: { model.settings[keyPath: value] }, set: {
                // One published update avoids rendering a discarded intermediate disabled state.
                var settings = model.settings
                settings[keyPath: value] = $0
                settings.isEnabled = true
                model.settings = settings
            }), in: range)
            .controlSize(.mini)
            .accessibilityLabel(L("screenshot.beautify.\(key)"))
            Text("\(Int((current * (suffix == "%" ? 100 : 1)).rounded())) \(suffix)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(textColor.opacity(0.6))
                .frame(width: 48, height: 24)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
        }
        .font(.system(size: 11))
    }
}

/// Transparency is a preview affordance only; the compositor preserves the exported alpha.
private struct ScreenshotTransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.22)))
            let side: CGFloat = 8
            for row in 0 ..< Int(ceil(size.height / side)) {
                for column in 0 ..< Int(ceil(size.width / side)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                    context.fill(Path(rect), with: .color(Color(white: 0.3)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
