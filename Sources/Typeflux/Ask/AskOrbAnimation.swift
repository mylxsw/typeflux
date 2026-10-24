import AppKit
import CoreImage
import QuartzCore
import SwiftUI

/// Animate only native layer properties. A SwiftUI timeline here also forced
/// the translucent chat window to update its layout and display list every frame.
struct AskOrbAnimation: NSViewRepresentable {
    var size: CGFloat
    var listening: Bool
    var palette: AskOrbPalette
    var colorScheme: ColorScheme

    func makeNSView(context _: Context) -> DropView {
        let view = DropView()
        view.configure(size: size, listening: listening, palette: palette, colorScheme: colorScheme)
        return view
    }

    func updateNSView(_ view: DropView, context _: Context) {
        view.configure(size: size, listening: listening, palette: palette, colorScheme: colorScheme)
    }

    final class DropView: AskOrbVisibility.VisibilityView {
        let content = CALayer()
        let fill = CAGradientLayer()
        let glow = CAGradientLayer()
        let glowSurface = CALayer()
        let highlight = CAGradientLayer()
        let shade = CAGradientLayer()
        private let masks = (0 ..< 4).map { _ in CAShapeLayer() }
        private let clock = AskOrbClock()
        private(set) var timer: Timer?
        private(set) var listening = false
        private var size: CGFloat = 88
        private var palette: AskOrbPalette?
        private var colorScheme: ColorScheme?
        private var visible = false

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(content)
            content.addSublayer(glowSurface)
            glowSurface.addSublayer(glow)
            for (index, gradient) in [glow, fill, highlight, shade].enumerated() {
                gradient.mask = masks[index]
                if gradient !== glow { content.addSublayer(gradient) }
            }
            highlight.type = .radial
            highlight.colors = [NSColor.white.withAlphaComponent(0.7).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
            highlight.startPoint = CGPoint(x: 0.34, y: 0.26)
            highlight.endPoint = CGPoint(x: 0.64, y: 0.56)
            shade.type = .radial
            shade.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.16).cgColor]
            shade.locations = [0, NSNumber(value: 0.28 / 0.52), 1]
            shade.startPoint = CGPoint(x: 0.5, y: 0.5)
            shade.endPoint = CGPoint(x: 1.02, y: 1.02)
            onChange = { [weak self] in self?.setVisible($0) }
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

        func configure(size: CGFloat, listening: Bool, palette: AskOrbPalette, colorScheme: ColorScheme) {
            self.listening = listening
            if size != self.size { self.size = size; needsLayout = true }
            if palette != self.palette || colorScheme != self.colorScheme {
                self.palette = palette
                self.colorScheme = colorScheme
                let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
                appearance?.performAsCurrentDrawingAppearance {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    let colors = palette.flowColors.map { NSColor($0).cgColor }
                    fill.colors = colors
                    glow.colors = colors
                    CATransaction.commit()
                }
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.transform = CATransform3DIdentity
            content.frame = bounds
            glowSurface.frame = bounds
            let rect = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
            for gradient in [fill, highlight, shade] { gradient.frame = rect }
            glow.bounds = CGRect(origin: .zero, size: rect.size)
            glow.position = CGPoint(x: rect.midX, y: rect.midY + size * 0.06)
            glow.transform = CATransform3DMakeScale(0.9, 0.9, 1)
            glowSurface.filters = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: size * 0.16]).map { [$0] }
            for mask in masks { mask.frame = CGRect(origin: .zero, size: rect.size) }
            render(clock.motion)
            CATransaction.commit()
        }

        private func setVisible(_ visible: Bool) {
            self.visible = visible
            if visible, timer == nil {
                tick()
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                timer.tolerance = 1.0 / 120
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else if !visible {
                timer?.invalidate()
                timer = nil
            }
        }

        private func tick() {
            guard visible else { return }
            render(clock.advance(to: Date(), listening: listening))
        }

        func render(_ motion: AskOrbMotion) {
            let path = AskFluidDropShape(phase: motion.phase, wobble: AskConversationOrb.wobble(energy: motion.energy))
                .path(in: CGRect(x: 0, y: 0, width: size, height: size)).cgPath
            let axis = AskConversationOrb.flow(motion.phase)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for mask in masks { mask.path = path }
            for gradient in [fill, glow] {
                gradient.startPoint = CGPoint(x: axis.start.x, y: axis.start.y)
                gradient.endPoint = CGPoint(x: axis.end.x, y: axis.end.y)
            }
            glow.opacity = Float(AskConversationOrb.glowOpacity(energy: motion.energy))
            let breath = AskConversationOrb.breath(motion.phase)
            content.transform = CATransform3DMakeScale(breath, breath, 1)
            CATransaction.commit()
        }

        deinit { timer?.invalidate() }
    }
}
