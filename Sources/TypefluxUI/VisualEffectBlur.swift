import AppKit
import SwiftUI

public struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat?

    public init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode,
                cornerRadius: CGFloat? = nil) {
        self.material = material
        self.blendingMode = blendingMode
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context _: Context) -> RoundedVisualEffectView {
        let view = RoundedVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.preferredCornerRadius = cornerRadius
        return view
    }

    public func updateNSView(_ nsView: RoundedVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = true
        nsView.preferredCornerRadius = cornerRadius
        nsView.needsLayout = true
    }
}
