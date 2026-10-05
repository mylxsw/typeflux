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
            let width = max(0, min(Self.sidebarWidth, geometry.size.width - 56))
            let progress = sidebarProgress(width: width)
            ZStack(alignment: .leading) {
                ChatDetailView(store: store, onOpenSidebar: { setSidebar(true) },
                               onNewConversation: newConversation)
                    .accessibilityHidden(sidebarOpen)
                    .allowsHitTesting(!sidebarOpen)
                // A thin leading strip opens the sidebar, like the system back swipe.
                Color.clear.frame(width: 18).contentShape(Rectangle())
                    .gesture(openGesture(width: width))
                    .allowsHitTesting(!sidebarOpen)
                    .accessibilityHidden(true)
                Color.black.opacity(0.18 * progress).ignoresSafeArea()
                    .onTapGesture { setSidebar(false) }
                    .gesture(closeGesture(width: width))
                    .accessibilityLabel(Text("Close sidebar"))
                    .accessibilityIdentifier("chat.sidebar.close")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { setSidebar(false) }
                    .allowsHitTesting(progress > 0)
                    .accessibilityHidden(!sidebarOpen)
                ChatSidebar(store: store, onSelect: select, onNewConversation: newConversation,
                            onSettings: openSettings)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .offset(x: (progress - 1) * width)
                    .gesture(closeGesture(width: width))
                    .accessibilityAddTraits(.isModal)
                    .allowsHitTesting(progress > 0)
                    .accessibilityHidden(!sidebarOpen)
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
                setSidebar(opens)
            }
    }

    private func closeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in dragOffset = min(0, value.translation.width) }
            .onEnded { value in
                let closes = -value.translation.width > width * 0.35 || -value.predictedEndTranslation.width > width
                setSidebar(!closes)
            }
    }

    private func setSidebar(_ open: Bool) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)) {
            sidebarOpen = open
            dragOffset = 0
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
