import SwiftUI

/// Shows a shortcut above a control without changing its size or click target.
struct EditorShortcutHint: ViewModifier {
    let key: String?
    let visible: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if visible, let key {
                Text(key)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .offset(x: 4, y: -5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
