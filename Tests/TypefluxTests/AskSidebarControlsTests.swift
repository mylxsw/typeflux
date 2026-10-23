import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask sidebar and folder controls", .serialized, .exclusiveUIState)
@MainActor
struct AskSidebarControlsTests {
    @Test(arguments: [false, true])
    func titleBarOmitsSavedDraftMenu(collapsed: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "sidebar-drafts-" + UUID().uuidString))
        defaults.set(collapsed, forKey: "ask.sidebarCollapsed")
        let fixture = try AskTestFixture(defaults: defaults)
        defer { fixture.model.resetSession() }
        fixture.model.savedChatDrafts = [.init(id: "saved-chat:test", draft: .init(text: "Saved input"))]
        let window = host(AskConversationView(model: fixture.model).defaultAppStorage(defaults),
                          dark: true, size: CGSize(width: 1100, height: 720))
        defer { window.close() }
        try await settle(window)
        #expect(find(L("ask.drafts.saved"), attribute: "accessibilityLabel", in: window) == nil)
        #expect(find("ask.workspace.new", in: window) != nil)
        #expect(find("ask.workspace.sidebar", in: window) != nil)
    }

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

    // MARK: - Sections (GUL-464)

    private func summaries(tasks: Int, chats: Int, now: Date) -> [AskConversationSummary] {
        (0 ..< tasks).map { AskConversationSummary(id: "t\($0)", title: "Task \($0)",
                                                    updatedAt: now.addingTimeInterval(-Double($0) * 60), kind: "work") }
            + (0 ..< chats).map { AskConversationSummary(id: "c\($0)", title: "Chat \($0)",
                                                         updatedAt: now.addingTimeInterval(-Double($0) * 90)) }
    }

    @Test func sectionsPutAFewTasksFirstThenChats() {
        let now = Date()
        let items = summaries(tasks: 8, chats: 3, now: now)
        let sections = AskHistorySections.make(items, expanded: false, selectedId: nil, now: now, calendar: .current)
        #expect(sections.tasks.map(\.id) == ["t0", "t1", "t2", "t3", "t4"])
        #expect(sections.hiddenTasks == 3)
        #expect(sections.chats.map(\.id) == ["c0", "c1", "c2"], "Legacy summaries without a kind are chats")
        let expanded = AskHistorySections.make(items, expanded: true, selectedId: nil, now: now, calendar: .current)
        #expect(expanded.tasks.count == 8 && expanded.hiddenTasks == 0)
    }

    @Test func aSelectedTaskPastTheLimitStaysVisible() {
        let now = Date()
        let items = summaries(tasks: 8, chats: 0, now: now)
        let sections = AskHistorySections.make(items, expanded: false, selectedId: "t7", now: now, calendar: .current)
        #expect(sections.tasks.map(\.id) == ["t0", "t1", "t2", "t3", "t4", "t7"])
        #expect(sections.hiddenTasks == 2)
        let few = AskHistorySections.make(summaries(tasks: 2, chats: 1, now: now), expanded: false,
                                          selectedId: "c0", now: now, calendar: .current)
        #expect(few.tasks.count == 2 && few.hiddenTasks == 0)
    }

    @Test(arguments: [false, true])
    func productionSidebarShowsTasksThenChatsWithoutFilters(signedIn: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "sidebar-sections-" + UUID().uuidString))
        let fixture = try AskTestFixture(localOnly: !signedIn, defaults: defaults)
        defer { fixture.model.resetSession() }
        let now = Date()
        for item in summaries(tasks: 7, chats: 2, now: now) {
            await fixture.api.seed(.init(id: item.id, title: item.title, revision: 1, updatedAt: item.updatedAt,
                                         messages: [], kind: item.kind ?? "chat"))
        }
        await fixture.model.refreshHistory()
        let window = host(AskConversationView(model: fixture.model).defaultAppStorage(defaults),
                          dark: true, size: CGSize(width: 1100, height: 720))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.history.storageFilter", in: window) == nil)
        #expect(find("ask.history.kind.all", in: window) == nil)
        #expect(find("ask.history.section.work", in: window) != nil)
        #expect(find("ask.history.section.chat", in: window) != nil)
        try snapshot(window, name: "sidebar-sections-signedIn-\(signedIn)")
        let more = try #require(find("ask.history.tasks.more", in: window))
        #expect(more.value(forKey: "accessibilityLabel") as? String == L("ask.history.showMore", 2))
        _ = more.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await settle(window)
        let less = try #require(find("ask.history.tasks.more", in: window))
        #expect(less.value(forKey: "accessibilityLabel") as? String == L("ask.history.showLess"))
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
