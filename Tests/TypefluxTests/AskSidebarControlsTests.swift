import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask sidebar and folder controls", .serialized, .exclusiveUIState)
@MainActor
struct AskSidebarControlsTests {
    @Test(arguments: [false, true])
    func environmentButtonHugsShortNamesAndCapsLongNames(compact: Bool) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.setConversationKind(.work, launcher: false)
        var widths: [CGFloat] = []
        for name in [nil, "src", String(repeating: "Long folder name ", count: 10)] as [String?] {
            fixture.model.draft.attachments = name.map { [.init(id: "folder", kind: .folder, name: $0)] }
            let window = host(HStack {
                AskWorkEnvironmentButton(model: fixture.model, compact: compact)
                Spacer(minLength: 0)
            })
            defer { window.close() }
            try await settle(window)
            let button = try #require(find("ask.composer.permissionMode", in: window))
            let frame = try #require(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            widths.append(frame.width)
            #expect(frame.height == AskMetrics.composerControlHeight)
            // Shield, folder, chevron and padding beside a name capped at 160pt.
            #expect(frame.width <= 160 + 80)
        }
        if compact {
            #expect(Set(widths).count == 1, "The compact control shows the shield alone, whatever the folder.")
        } else {
            #expect(widths[1] < widths[0], "A shorter folder name releases space to adjacent controls.")
            #expect(widths[2] > widths[0], "A long name grows the control up to its cap, then truncates.")
        }
    }

    @Test(arguments: [false, true])
    func unfilteredStorageIconIsNeutralAndMenuStillSelects(dark: Bool) async throws {
        let state = StorageSelection()
        let window = host(StorageMenu(state: state), dark: dark)
        defer { window.close() }
        try await settle(window)
        let content = try #require(window.contentView)
        let control = try #require(descendants(content).compactMap { $0 as? TFNativeMenuControl.MenuButton }.first)
        #expect(control.isEnabled)
        let menu = try #require(control.menu)
        #expect(menu.items.map(\.title) == AskHistoryFilter.allCases.map { L($0.titleKey) })
        #expect(menu.items.filter { $0.state == .on }.map(\.tag) == [0])

        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        var bluePixels = 0
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.blueComponent > color.redComponent + 0.15,
                   color.blueComponent > color.greenComponent + 0.08 { bluePixels += 1 }
            }
        }
        #expect(bluePixels == 0, "All conversations must not inherit the system's blue menu tint.")
        try snapshot(window, name: "storage-all-\(dark ? "dark" : "light")")

        for (index, filter) in AskHistoryFilter.allCases.enumerated().reversed() {
            let item = menu.items[index]
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(state.value == filter)
            try await settle(window)
            #expect(control.menu?.items.filter { $0.state == .on }.map(\.tag) == [index])
        }
    }

    @Test(arguments: [(false, false), (true, false), (true, true)])
    func productionSidebarKeepsStorageFilterVisibleAndFunctional(signedIn: Bool, hasLocalHistory: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "sidebar-filter-" + UUID().uuidString))
        let fixture = try AskTestFixture(localOnly: !signedIn, defaults: defaults)
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "main", title: "Main conversation", revision: 1,
                                     updatedAt: Date(), messages: [], kind: "chat"))
        if hasLocalHistory {
            await fixture.localAPI.seed(.init(id: "local", title: "Local conversation", revision: 1,
                                              updatedAt: Date(), messages: [], kind: "chat"))
        }
        await fixture.model.refreshHistory()
        #expect(fixture.model.isSignedIn == signedIn)
        let window = host(AskConversationView(model: fixture.model).defaultAppStorage(defaults),
                          dark: true, size: CGSize(width: 1100, height: 720))
        defer { window.close() }
        try await settle(window)
        let element = try #require(find("ask.history.storageFilter", in: window))
        let frame = try #require(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        #expect(frame.width >= AskHistoryFilterBar.height - 0.5)
        #expect(window.frame.contains(frame), "The filter stays visible in the production sidebar.")
        let content = try #require(window.contentView)
        let control = try #require(descendants(content).compactMap { $0 as? TFNativeMenuControl.MenuButton }
            .first { $0.accessibilityIdentifier() == "ask.history.storageFilter" })
        try snapshot(window, name: "sidebar-signedIn-\(signedIn)-local-\(hasLocalHistory)")
        for filter in [AskHistoryFilter.cloud, .local, .all] {
            let index = try #require(AskHistoryFilter.allCases.firstIndex(of: filter))
            let item = try #require(control.menu?.items[index])
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            try await settle(window)
            #expect(control.menu?.items[index].state == .on)
            let emptyTitle = L("ask.history.empty")
            let empty = find(emptyTitle, attribute: "accessibilityValue", in: window) != nil
                || find(emptyTitle, attribute: "accessibilityLabel", in: window) != nil
            let expectedEmpty = filter == .cloud ? !signedIn : filter == .local && signedIn && !hasLocalHistory
            try snapshot(window, name: "sidebar-signedIn-\(signedIn)-local-\(hasLocalHistory)-\(filter.rawValue)")
            #expect(empty == expectedEmpty, "The visible filter must update the actual history list.")
        }
    }

    @Test(arguments: [false, true])
    func historyTimeAppearsOnlyWhileHovering(busy: Bool) async throws {
        let window = host(HistoryRow(busy: busy))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.history.time", in: window) == nil)
        try snapshot(window, name: "history-resting-\(busy)")
        try hover(window, inside: true)
        try await settle(window)
        #expect((find("ask.history.time", in: window) != nil) == !busy)
        try snapshot(window, name: "history-hover-\(busy)")
        try hover(window, inside: false)
        try await settle(window)
        #expect(find("ask.history.time", in: window) == nil)
    }

    private final class StorageSelection: ObservableObject {
        @Published var value = AskHistoryFilter.all
    }

    private struct StorageMenu: View {
        @ObservedObject var state: StorageSelection
        var body: some View { AskHistoryStorageMenu(selection: $state.value) }
    }

    private struct HistoryRow: View {
        let busy: Bool
        @Namespace private var selection
        var body: some View {
            AskHistoryRow(title: "A conversation with a longer title", updatedAt: .distantPast,
                          selected: false, busy: busy, selectionSpace: selection,
                          onSelect: {}, onDelete: {})
                .frame(width: 260)
        }
    }

    private func host(_ view: some View, dark: Bool = false, size: CGSize = CGSize(width: 600, height: 60)) -> NSWindow {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AskTheme.surface)
            .environment(\.colorScheme, dark ? .dark : .light))
        window.orderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func find(_ identifier: String, attribute: String = "accessibilityIdentifier", in window: NSWindow) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString(attribute)),
               object.value(forKey: attribute) as? String == identifier { return object }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }

    private func hover(_ window: NSWindow, inside: Bool) throws {
        let content = try #require(window.contentView)
        let point = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        var delivered = false
        for view in descendants(content) {
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(view.convert(point, from: content)), let owner = area.owner as? NSResponder else { continue }
                let event = SidebarHoverEvent(area: area, point: content.convert(point, to: nil), window: window, inside: inside)
                if inside { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
                delivered = true
            }
        }
        #expect(delivered)
    }

    private func snapshot(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_SIDEBAR_SCREENSHOTS"],
              let content = window.contentView else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent(name + ".png"))
    }
}

private final class SidebarHoverEvent: NSEvent {
    private let area: NSTrackingArea
    private let point: NSPoint
    private let targetWindowNumber: Int
    private let eventType: NSEvent.EventType

    init(area: NSTrackingArea, point: NSPoint, window: NSWindow, inside: Bool) {
        self.area = area
        self.point = point
        targetWindowNumber = window.windowNumber
        eventType = inside ? .mouseEntered : .mouseExited
        super.init()
    }

    required init?(coder: NSCoder) { nil }
    override var trackingArea: NSTrackingArea? { area }
    override var locationInWindow: NSPoint { point }
    override var windowNumber: Int { targetWindowNumber }
    override var type: NSEvent.EventType { eventType }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
