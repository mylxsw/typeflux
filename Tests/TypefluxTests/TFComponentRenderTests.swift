import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Hosts the shared components and the component gallery in real windows: every view body
/// renders in light and dark, native menus drive their bindings, and the gallery window opens
/// and closes cleanly. Set `TYPEFLUX_COMPONENT_SNAPSHOTS=<dir>` to keep PNGs of each page.
@Suite("Shared component rendering", .serialized, .exclusiveUIState)
@MainActor
struct TFComponentRenderTests {
    final class Box<Value>: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }

        var binding: Binding<Value> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    @Test func everyGalleryPageRendersInLightAndDark() async throws {
        for section in ComponentGallerySection.allCases {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for compact in [false, true] where compact == false || section == .compositions || section == .tabs {
                    let page = ComponentGalleryPage(section: section).tfCompactLayout(compact)
                        .frame(width: compact ? 640 : 980).padding(24).background(ModelVisualStyle.canvas)
                    try await render(page, size: NSSize(width: compact ? 688 : 1028, height: 1500), appearance: appearance,
                                     name: "\(section.rawValue)-\(name)\(compact ? "-compact" : "")")
                }
            }
        }
    }

    @Test func galleryShellRendersInEveryStyle() async throws {
        for style in InterfaceStyle.allCases {
            try await render(ComponentGalleryView().environment(\.interfaceStyle, style),
                             size: NSSize(width: 1180, height: 820), appearance: .darkAqua, name: "gallery-\(style.rawValue)")
        }
    }

    @Test func popUpButtonUpdatesItsBindingFromTheNativeMenu() async throws {
        let box = Box("zh")
        let view = TFPopUpButton(title: "Language", options: GallerySamples.languages, selection: box.binding,
                                 width: TFMetrics.formControlWidth, identifier: "language")
        let (window, host) = host(view, size: NSSize(width: 260, height: 60))
        defer { close(window) }
        try await settle(host)
        let button = try #require(popUpButton(in: host))
        #expect(button.itemTitles == ["简体中文", "English", "日本語", "Follow System"])
        #expect(button.indexOfSelectedItem == 0)
        #expect(button.accessibilityIdentifier() == "language")
        button.menu?.performActionForItem(at: 1)
        #expect(box.value == "en")
    }

    @Test func filterAndMenuButtonsRunTheirNativeMenus() async throws {
        let filter = Box("all")
        var ran: [String] = []
        let view = HStack {
            TFFilterMenu(title: "Type", options: [TFOption("all", "All", count: 3), TFOption("ai", "AI", count: 1)],
                         selection: filter.binding, defaultValue: "all")
            TFMenuButton(title: "More", systemImage: "ellipsis", actions: [
                .action("Import") { ran.append("import") }, .separator, .action("Delete", destructive: true) { ran.append("delete") }
            ])
        }
        let (window, host) = host(view, size: NSSize(width: 360, height: 60))
        defer { close(window) }
        try await settle(host)
        let buttons = allPopUpButtons(in: host)
        #expect(buttons.count == 2)
        let filterButton = try #require(buttons.first { !$0.pullsDown })
        filterButton.menu?.performActionForItem(at: 1)
        #expect(filter.value == "ai")
        let menuButton = try #require(buttons.first { $0.pullsDown })
        // Item 0 of a pull-down menu is its closed title.
        #expect(menuButton.itemTitles.first == "More")
        menuButton.menu?.performActionForItem(at: 3)
        menuButton.menu?.performActionForItem(at: 1)
        #expect(ran == ["delete", "import"])
    }

    @Test func adaptiveComponentsFoldInCompactLayouts() async throws {
        let pane = Box("a")
        let filter = Box("all")
        let sections = [TFPaneSection("Group", items: [TFPaneItem("a", "Alpha", systemImage: "a.circle"),
                                                       TFPaneItem("b", "Beta", systemImage: "b.circle", status: .inactive)])]
        let options = [TFOption("all", "All"), TFOption("x", "X")]
        func layout(compact: Bool) -> some View {
            VStack {
                TFPaneLayout(sections: sections, selection: pane.binding) { Text(verbatim: "content") }
                TFFilterControl(title: "Filter", options: options, selection: filter.binding, defaultValue: "all")
            }
            .tfCompactLayout(compact)
        }
        let (regularWindow, regular) = host(layout(compact: false), size: NSSize(width: 800, height: 300))
        try await settle(regular)
        #expect(allPopUpButtons(in: regular).isEmpty)
        close(regularWindow)
        let (compactWindow, compact) = host(layout(compact: true), size: NSSize(width: 500, height: 300))
        defer { close(compactWindow) }
        try await settle(compact)
        let pickers = allPopUpButtons(in: compact)
        #expect(pickers.count == 2)
        let panePicker = try #require(pickers.first { $0.itemTitles.contains("Beta") })
        let index = try #require(panePicker.menu?.items.firstIndex { $0.title == "Beta" })
        panePicker.menu?.performActionForItem(at: index)
        #expect(pane.value == "b")
    }

    @Test func componentsRenderInEveryStateAndSize() async throws {
        let text = Box("query")
        let toggle = Box(true)
        let view = VStack(alignment: .leading, spacing: 12) {
            ForEach(TFControlSize.allCases) { size in
                HStack {
                    ForEach(TFButtonKind.allCases) { kind in
                        TFButton(title: "Save", systemImage: "checkmark", kind: kind, size: size) {}
                        TFButton(title: "Delete", kind: kind, destructive: true, size: size, isLoading: true) {}
                    }
                    TFButton(title: "More", systemImage: "ellipsis", size: size, iconOnly: true, isLoading: size == .small) {}
                    TFButton(title: "Menu", size: size, showsMenuIndicator: true) {}
                }
            }
            TFSearchField(placeholder: "Search", text: text.binding, resultCount: 3, onMoveDown: {}, onSubmit: {},
                          identifier: "search")
            TFSearchField(placeholder: "Search", text: Box("").binding, placement: .container)
            TextField("URL", text: text.binding).textFieldStyle(TFTextFieldStyle(monospaced: true, isError: true))
            TFFieldMessage(text: "Error")
            TFFieldMessage(text: "Hint", tone: .hint)
            TFFieldMessage(text: "Warning", tone: .warning)
            TFSwitch(title: "On", isOn: toggle.binding)
            TFSectionHeader(title: "Header", count: 2) { TFButton(title: "New") {} }
            TFListGroup([1, 2], id: \.self) { value in
                TFListRow(title: "Row \(value)", subtitle: "Detail", tags: ["Tag"], monospacedTags: true, query: "row",
                          density: value == 1 ? .regular : .compact, isSelected: value == 2, action: {}) {
                    TFIconTile(systemImage: "star")
                } accessory: {
                    TFStatusLabel(text: "Running", level: .success, tintsText: true)
                    TFChevron()
                }
            }
            TFRichPicker(title: "Model", sections: GallerySamples.models, selection: Box("gpt").binding)
            TFMenuPanel(sections: GallerySamples.models, selection: "cloud", searchable: nil) { _ in }
            TFEmptyState(systemImage: "tray", title: "Empty") { EmptyView() }
            TFSearchEmptyState(query: "zzz", onClear: {})
            TFKeyCap(text: "⌘F")
            TFSpinner(size: .large)
        }
        .padding(20)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try await render(view, size: NSSize(width: 1400, height: 1200), appearance: appearance,
                             name: "components-\(appearance == .aqua ? "light" : "dark")")
        }
    }

    @Test func galleryWindowOpensOnceAndReleasesOnClose() async throws {
        let app = GalleryFakeActivationPolicy()
        var activations = 0
        let controller = ComponentGalleryWindowController(dock: DockVisibilityController(app: app)) { activations += 1 }
        controller.show()
        let window = try #require(controller.window)
        #expect(window.identifier == ComponentGalleryWindowController.windowIdentifier)
        #expect(app.policy == .regular)
        controller.show()
        #expect(controller.window === window)
        #expect(activations == 2)
        window.close()
        #expect(controller.window == nil)
        #expect(app.policy == .accessory)
    }

    // MARK: - Helpers

    private final class GalleryFakeActivationPolicy: ActivationPolicyControlling {
        var policy: NSApplication.ActivationPolicy = .accessory
        var currentActivationPolicy: NSApplication.ActivationPolicy { policy }
        func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) { self.policy = policy }
    }

    private func host(_ view: some View, size: NSSize, appearance: NSAppearance.Name = .darkAqua)
        -> (NSWindow, NSHostingView<AnyView>) {
        _ = NSApplication.shared
        let frame = NSRect(origin: NSPoint(x: -10000, y: -10000), size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        return (window, hosting)
    }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    private func allPopUpButtons(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { allPopUpButtons(in: $0) }
    }

    private func popUpButton(in view: NSView) -> NSPopUpButton? {
        allPopUpButtons(in: view).first
    }

    private func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, name: String) async throws {
        let (window, hosting) = host(view, size: size, appearance: appearance)
        defer { close(window) }
        try await settle(hosting)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 4000, "\(name) rendered blank")
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_COMPONENT_SNAPSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("\(name).png"))
        }
    }
}
