import AppKit
import SwiftUI
import Testing
@testable import TypefluxUI

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct TypefluxWindowToolbarLayoutTests {
    @Test(arguments: InterfaceStyle.allCases)
    func customToolbarItemsHaveFiniteNonzeroFramesAcrossRebuilds(style: InterfaceStyle) async throws {
        for title in ["", String(repeating: "Conversation ", count: 30)] {
            let action = TypefluxToolbarAction(id: "sidebar", title: "Sidebar", systemImage: "sidebar.left") {}
            let view = TypefluxWindow(title: title, search: TypefluxSearchState(), searchPrompt: "Search",
                                      groups: [.init(id: "actions", actions: [
                                        .init(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise") {}
                                      ])],
                                      prominent: .init(id: "new", title: "New", systemImage: "plus") {},
                                      center: AnyView(EmptyView()), sidebarToggle: action) {
                List { Text("History") }
            } detail: { Text("Content") }
            try await TypefluxNavigationTestSupport.withWindow(view.environment(\.interfaceStyle, style)) { window, _ in
                let items = try #require(window.toolbar?.items)
                let titleItem = try #require(items.first {
                    $0.itemIdentifier.rawValue.contains(TypefluxWindowTitleBridge.itemIdentifier)
                })
                let titleView = try #require(titleItem.view)
                #expect(titleView.frame.width > 0 && titleView.frame.width.isFinite)
                #expect(titleView.frame.height > 0 && titleView.frame.height.isFinite)
                let custom = items.filter { $0.itemIdentifier.rawValue.contains("typeflux.window.") }
                for item in custom {
                    if let view = item.view {
                        #expect(view.frame.width > 0 && view.frame.width.isFinite, "Invalid width for \(item.itemIdentifier)")
                        #expect(view.frame.height > 0 && view.frame.height.isFinite, "Invalid height for \(item.itemIdentifier)")
                    }
                }
                for identifier in ["typeflux.toolbar.refresh", "typeflux.toolbar.new"] {
                    let element = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                        $0.value("accessibilityIdentifier") as? String == identifier
                    })
                    #expect(element.frame.width > 0 && element.frame.width.isFinite)
                    #expect(element.frame.height > 0 && element.frame.height.isFinite)
                }
                window.contentView = nil
                window.toolbar = nil
                window.close()
                try await Task.sleep(for: .milliseconds(40))
                #expect(!window.isVisible)
            }
        }
    }
}
