import SwiftUI
import TypefluxChat
import UIKit

/// The app opens on a new conversation, like the Mac window. History lives in a
/// sidebar that slides over the conversation from the leading edge.
struct ChatRootView: View {
    @Bindable var store: ChatStore
    @Bindable var preferences: ChatPreferences
    @State private var sidebarOpen = false
    @State private var dragOffset: CGFloat = 0
    @State private var showSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let sidebarWidth: CGFloat = 318

    var body: some View {
        GeometryReader { geometry in
            let width = min(Self.sidebarWidth, geometry.size.width - 56)
            let progress = sidebarProgress(width: width)
            ZStack(alignment: .leading) {
                ChatDetailView(store: store, onOpenSidebar: { setSidebar(true) },
                               onNewConversation: newConversation)
                    .accessibilityHidden(sidebarOpen)
                // A thin leading strip opens the sidebar, like the system back swipe.
                Color.clear.frame(width: 18).contentShape(Rectangle())
                    .gesture(openGesture(width: width))
                    .allowsHitTesting(!sidebarOpen)
                    .accessibilityHidden(true)
                if progress > 0 {
                    Color.black.opacity(0.18 * progress).ignoresSafeArea()
                        .onTapGesture { setSidebar(false) }
                        .gesture(closeGesture(width: width))
                        .accessibilityLabel(Text("Close sidebar"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { setSidebar(false) }
                    ChatSidebar(store: store, onSelect: select, onNewConversation: newConversation,
                                onSettings: openSettings)
                        .frame(width: width)
                        .padding(.vertical, 8).padding(.leading, 8)
                        .offset(x: (progress - 1) * (width + 16))
                        .gesture(closeGesture(width: width))
                        .accessibilityAddTraits(.isModal)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ChatSettingsView(store: store, preferences: preferences)
        }
        .onChange(of: store.isAuthenticated) { _, authenticated in
            if !authenticated {
                sidebarOpen = false
            }
        }
    }

    private func sidebarProgress(width: CGFloat) -> CGFloat {
        let base: CGFloat = sidebarOpen ? 1 : 0
        return min(max(base + dragOffset / max(width, 1), 0), 1)
    }

    private func openGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in dragOffset = max(0, value.translation.width) }
            .onEnded { value in
                let opens = value.translation.width > width * 0.35 || value.predictedEndTranslation.width > width
                dragOffset = 0
                setSidebar(opens)
            }
    }

    private func closeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in dragOffset = min(0, value.translation.width) }
            .onEnded { value in
                let closes = -value.translation.width > width * 0.35 || -value.predictedEndTranslation.width > width
                dragOffset = 0
                setSidebar(!closes)
            }
    }

    private func setSidebar(_ open: Bool) {
        if open {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)) {
            sidebarOpen = open
        }
    }

    private func select(_ id: String) {
        setSidebar(false)
        Task { await store.select(id) }
    }

    private func newConversation() {
        store.newConversation()
        setSidebar(false)
    }

    private func openSettings() {
        setSidebar(false)
        showSettings = true
    }
}
