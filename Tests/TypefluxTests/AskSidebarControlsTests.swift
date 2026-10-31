import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Typeflux

@Suite("Ask sidebar and folder controls", .serialized, .exclusiveUIState)
@MainActor
struct AskSidebarControlsTests {
    @Test(arguments: [InterfaceStyle.liquidGlass, .classic], [false, true])
    func headerTitlesUseRenderedWidthAndKeepTheirFullText(style: InterfaceStyle, collapsed: Bool) async throws {
        let suite = "header-title-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(collapsed, forKey: "ask.sidebarCollapsed")
        let fixture = try AskTestFixture(defaults: defaults)
        defer { fixture.model.resetSession() }
        let titles = [
            ("chinese", String(repeating: "很长的对话标题", count: 12)),
            ("english", "Understanding how window dragging works"),
            ("long-english", String(repeating: "A longer conversation title ", count: 8)),
            ("short", "Hi"),
            ("mixed", "多语言标题 with family 👨‍👩‍👧‍👦 and window dragging"),
        ]
        for (id, title) in titles {
            var conversation = AskConversation(id: id, title: title, revision: 1, updatedAt: Date(), messages: [])
            conversation.run = .init(id: "run-" + id, deviceId: "device", status: "completed", steps: 1,
                                     updatedAt: Date(), tools: [], pending: [])
            await fixture.api.seed(conversation)
        }
        for width in [CGFloat(1100), 440] {
            let window = host(AskConversationView(model: fixture.model).defaultAppStorage(defaults)
                .environment(\.interfaceStyle, style), dark: collapsed, size: CGSize(width: width, height: 720))
            defer { window.close() }
            for (id, title) in titles {
                await fixture.model.select(id)
                try await settle(window)
                let label = try #require(find("ask.workspace.title", in: window))
                let frame = try #require(label.value(forKey: "accessibilityFrame") as? NSValue).rectValue
                #expect(frame.width > 0 && frame.width <= AskConversationHeaderTitle.maximumWidth + 1,
                        "Titles share one visual width limit regardless of language")
                // AppKit exposes a static text's accessible name through its value.
                let accessibleTitle = label.value(forKey: "accessibilityValue") as? String
                    ?? label.value(forKey: "accessibilityLabel") as? String
                #expect(accessibleTitle == title)
                #expect(fixture.model.selected?.title == title, "Display truncation never changes the saved title")
                if width == 1100, id == "english" {
                    let font = NSFont.systemFont(ofSize: style.usesGlass ? 13.5 : 13, weight: .semibold)
                    let oldWidth = (String(title.prefix(24)) as NSString).size(withAttributes: [.font: font]).width
                    #expect(frame.width > oldWidth + 20, "English must display more than the former 24-character preview")
                }
                if id == "short" { #expect(frame.width < 40, "Short titles must not expand to the maximum width") }
                let usage = try #require(find("ask.workspace.usage", in: window))
                let usageFrame = try #require(usage.value(forKey: "accessibilityFrame") as? NSValue).rectValue
                #expect(frame.maxX <= usageFrame.minX, "The title leaves its tools available")
                try snapshot(window, name: "header-title-width-\(id)-\(style.rawValue)-\(collapsed)-\(Int(width))")
            }
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .frosted, .classic], [false, true])
    func headerEmptySpaceCatchesDragsAboveTheTranscript(style: InterfaceStyle, collapsed: Bool) async throws {
        let suite = "header-drag-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(collapsed, forKey: "ask.sidebarCollapsed")
        let fixture = try AskTestFixture(defaults: defaults)
        defer { fixture.model.resetSession() }
        let now = Date()
        await fixture.api.seed(.init(id: "header-drag", title: "Header dragging", revision: 1, updatedAt: now, messages: [
            .init(id: "answer", role: "assistant",
                  text: String(repeating: "Selectable transcript text under the floating header.\n\n", count: 50),
                  createdAt: now),
        ]))
        await fixture.model.refreshHistory()
        for width in [CGFloat(1100), 440] {
            let window = host(AskConversationView(model: fixture.model).defaultAppStorage(defaults)
                .environment(\.interfaceStyle, style), dark: collapsed, size: CGSize(width: width, height: 720))
            defer { window.close() }
            for populated in [false, true] {
                if populated { await fixture.model.select("header-drag") }
                else { fixture.model.newConversation() }
                try await settle(window)
                let content = try #require(window.contentView)
                let drag = try #require(descendants(content).compactMap { $0 as? AskConversationTitleBarDragView }.first)
                let frame = drag.convert(drag.bounds, to: nil)
                #expect(abs(frame.height - AskMetrics.titleBarRowHeight) < 0.5)
                #expect(abs(frame.maxY - content.bounds.height) < 0.5)
                #expect(drag.acceptsFirstMouse(for: nil))
                func hit(_ point: NSPoint) -> NSView? {
                    content.hitTest(content.superview?.convert(point, from: nil) ?? point)
                }
                // This gap used to select the visually hidden transcript. Check
                // the whole title row, including the space below the native title bar.
                let x = frame.minX + frame.width * 0.72
                for distance in [CGFloat(3), 26, 49] {
                    let grabsWindow = hit(NSPoint(x: x, y: frame.maxY - distance)) === drag
                    #expect(grabsWindow,
                            "\(style), collapsed: \(collapsed), populated: \(populated), width: \(width), y: \(distance)")
                }
                #expect(!(hit(NSPoint(x: x, y: frame.minY - 8)) is AskConversationTitleBarDragView),
                        "The gradient tail must leave the transcript interactive")
                let newButton = try AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.new", in: window)
                #expect(!(hit(newButton) is AskConversationTitleBarDragView))
                if populated {
                    let usage = try AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.usage", in: window)
                    #expect(!(hit(usage) is AskConversationTitleBarDragView), "Header tools stay above the drag region")
                }
                try snapshot(window, name: "header-drag-\(style.rawValue)-\(collapsed)-\(populated)-\(Int(width))")
            }
        }
    }

    @Test func headerDragUsesTheNativeWindowDragOperation() throws {
        let window = HeaderDragTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let drag = AskConversationTitleBarDragView(frame: NSRect(x: 0, y: 148, width: 400, height: 52))
        window.contentView?.addSubview(drag)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 174),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        drag.mouseDown(with: event)
        #expect(window.dragEvent === event)
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .frosted], [false, true])
    func `full window material has no rectangular glass edge`(style: InterfaceStyle, dark: Bool) async throws {
        let window = host(HStack(spacing: 0) {
            AskEdgeColumnBackdrop().frame(width: 264)
            AskWindowBackdrop()
        }.environment(\.interfaceStyle, style), dark: dark, size: CGSize(width: 900, height: 600))
        defer { window.close() }
        try await settle(window)
        let content = try #require(window.contentView)
        let views = descendants(content)
        #expect(!views.contains { String(describing: type(of: $0)).contains("NSGlassEffectView") })
        let materials = views.compactMap { $0 as? NSVisualEffectView }
        #expect(materials.count >= 2)
        #expect(materials.allSatisfy { $0.blendingMode == .behindWindow })
        if style == .liquidGlass {
            #expect(materials.allSatisfy { $0.material == .underWindowBackground })
        }
        try snapshot(window, name: "window-material-\(style.rawValue)-\(dark)")
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `dragging history divider updates layout and restores its width`(style: InterfaceStyle) async throws {
        let suite = "sidebar-resize-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "ask.sidebarCollapsed")
        let fixture = try AskTestFixture(defaults: defaults)
        defer { fixture.model.resetSession() }
        func open(_ width: CGFloat = 1300) -> NSWindow {
            host(AskConversationView(model: fixture.model).defaultAppStorage(defaults)
                .environment(\.interfaceStyle, style), dark: true, size: CGSize(width: width, height: 720))
        }
        let window = open()
        defer { window.close() }
        try await settle(window)
        let content = try #require(window.contentView)
        let handle = try #require(descendants(content)
            .compactMap { $0 as? AskSidebarResizeView }.first)
        #expect(abs(handle.convert(handle.bounds, to: nil).midX - AskMetrics.sidebarWidth) < 1)
        #expect(!handle.mouseDownCanMoveWindow)
        #expect(content
            .hitTest(content.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), from: handle)) === handle)
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        try handle.mouseDown(with: event(.leftMouseDown, x: 264))
        try handle.mouseDragged(with: event(.leftMouseDragged, x: 360))
        try await settle(window)
        #expect(abs(handle.convert(handle.bounds, to: nil).midX - 360) < 1)
        #expect(defaults.object(forKey: AskSidebarWidth.key) == nil, "Persist only when the drag ends")
        try handle.mouseDragged(with: event(.leftMouseDragged, x: 400))
        try await settle(window)
        try handle.mouseUp(with: event(.leftMouseUp, x: 400))
        try await settle(window)
        #expect(defaults.double(forKey: AskSidebarWidth.key) == 400)
        #expect(abs(handle.convert(handle.bounds, to: nil).midX - 400) < 1)
        #expect(handle.accessibilityPerformDecrement())
        try await settle(window)
        #expect(defaults.double(forKey: AskSidebarWidth.key) == 384)
        #expect(handle.accessibilityPerformIncrement())
        try await settle(window)
        #expect(defaults.double(forKey: AskSidebarWidth.key) == 400)
        try snapshot(window, name: "resized-sidebar-\(style.rawValue)")
        let reopened = open()
        defer { reopened.close() }
        try await settle(reopened)
        let restoredContent = try #require(reopened.contentView)
        let restored = try #require(descendants(restoredContent)
            .compactMap { $0 as? AskSidebarResizeView }.first)
        #expect(abs(restored.convert(restored.bounds, to: nil).midX - 400) < 1)
        let narrow = open(800)
        defer { narrow.close() }
        try await settle(narrow)
        let narrowContent = try #require(narrow.contentView)
        #expect(!descendants(narrowContent).contains { $0 is AskSidebarResizeView })
        #expect(defaults.double(forKey: AskSidebarWidth.key) == 400)
        // At the exact layout limit, rounding up would hide the sidebar on release.
        defaults.set(264.0, forKey: AskSidebarWidth.key)
        let fractional = open(960.75)
        defer { fractional.close() }
        try await settle(fractional)
        let fractionalContent = try #require(fractional.contentView)
        let fractionalHandle = try #require(descendants(fractionalContent)
            .compactMap { $0 as? AskSidebarResizeView }.first)
        let maximum = fractionalContent.bounds.width - AskWorkspaceLayout.comfortableContentWidth
        fractionalHandle.resize?(1000)
        try await settle(fractional)
        fractionalHandle.resize?(nil)
        try await settle(fractional)
        #expect(defaults.double(forKey: AskSidebarWidth.key) == Double(maximum))
        #expect(descendants(fractionalContent).contains { $0 === fractionalHandle })
    }

    @Test(arguments: [CGFloat(440), 1100], [InterfaceStyle.liquidGlass, .classic])
    func localConversationsOmitStorageMarks(width: CGFloat, style: InterfaceStyle) async throws {
        let suite = "sidebar-local-marks-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "ask.sidebarCollapsed")
        let fixture = try AskTestFixture(defaults: defaults)
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "synced", title: "Synced chat", revision: 1,
                                    updatedAt: Date(), messages: [], kind: "chat"))
        await fixture.localAPI.seed(.init(id: "local", title: "My task", revision: 1,
                                         updatedAt: Date(), messages: [], kind: "work"))
        await fixture.model.refreshHistory()
        await fixture.model.select("local")
        #expect(fixture.model.isLocal("local"))
        let window = host(AskConversationView(model: fixture.model).defaultAppStorage(defaults)
            .environment(\.interfaceStyle, style).environment(\.askGlassMaterialOverride, .opaque),
                          dark: true, size: CGSize(width: width, height: 720))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.workspace.storageMark", in: window) == nil)
        #expect(find("ask.workspace.local", in: window) == nil)
        #expect(AskCommandCatalog.commands(fixture.model.commandContext(launcher: false))
            .contains { $0.name == "sync" && $0.enabled })
        if width < AskMetrics.sidebarWidth + AskWorkspaceLayout.comfortableContentWidth {
            let toggle = try #require(find("ask.workspace.sidebar", in: window))
            _ = toggle.perform(NSSelectorFromString("accessibilityPerformPress"))
            try await Task.sleep(for: .milliseconds(300))
            try await settle(window)
        }
        let row = try #require(find("ask.history.row.local", in: window))
        #expect(find("ask.history.row.synced", in: window) != nil)
        #expect(find("ask.history.localMark", in: window) == nil)
        let label = row.value(forKey: "accessibilityLabel") as? String ?? ""
        #expect(label.contains(L(AskConversationKind.work.titleKey)), "The task mark remains in the row label: \(label)")
        try snapshot(window, name: "local-no-marks-\(Int(width))-\(style.rawValue)")
    }

    @Test(arguments: [CGFloat(440), 960], [(false, InterfaceStyle.liquidGlass), (true, .liquidGlass),
                                         (false, .classic), (true, .classic)])
    func usageRequiresAConversationBeforeAndAfterOpeningFiles(width: CGFloat,
                                                            configuration: (Bool, InterfaceStyle)) async throws {
        let (hasConversation, style) = configuration
        let suite = "sidebar-usage-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ask.sidebarCollapsed")
        let fixture = try AskTestFixture(defaults: defaults)
        defer { fixture.model.resetSession() }
        fixture.tools.browserWorkspace = AskBrowserWorkspace(policy: AskBrowserSitePolicy(defaults: defaults),
                                                            dataStore: .nonPersistent())
        if hasConversation {
            await fixture.api.seed(.init(id: "usage-chat", title: "Existing chat", revision: 1,
                                        updatedAt: Date(), messages: []))
            await fixture.model.select("usage-chat")
        }
        let window = host(AskConversationView(model: fixture.model)
            .defaultAppStorage(defaults)
            .environment(\.interfaceStyle, style)
            .environment(\.askGlassMaterialOverride, .opaque),
                          dark: true, size: CGSize(width: width, height: 720))
        defer { window.close() }
        try await settle(window)
        #expect((find("ask.workspace.usage", in: window) != nil) == hasConversation)
        let toggle = try #require(find("ask.workspace.sidePanel", in: window))
        _ = toggle.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await Task.sleep(for: .milliseconds(300))
        try await settle(window)
        #expect(find("ask.sidePanel.filesTab", in: window) != nil)
        if width >= AskWorkspaceLayout.minimumDockedContentWidth + AskWorkspaceLayout.minimumDockedPanelWidth {
            // Opening Files changes the wide header into the compact header at this width.
            #expect(find("ask.workspace.sidePanel", in: window) != nil)
            #expect((find("ask.workspace.usage", in: window) != nil) == hasConversation)
        }
        try snapshot(window, name: "usage-files-\(Int(width))-\(hasConversation)-\(style.rawValue)")
        let close = try #require(find("ask.workspace.drawer.close", in: window))
        _ = close.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await Task.sleep(for: .milliseconds(300))
        try await settle(window)
        #expect(find("ask.sidePanel", in: window) == nil)
        #expect(find("ask.workspace.sidePanel", in: window) != nil)
        #expect((find("ask.workspace.usage", in: window) != nil) == hasConversation)
    }

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
            // Permission icon and title, folder, chevron and padding beside a folder name capped at 160pt.
            let modeTitleWidth = (AskPermissionMode.standard.title as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)
            ]).width
            #expect(frame.width <= 160 + 80 + modeTitleWidth)
        }
        if compact {
            #expect(Set(widths).count == 1, "The compact control keeps the permission icon and name, whatever the folder.")
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

    @Test(arguments: [(false, false, false), (true, false, false), (true, true, false), (true, true, true)])
    func productionSidebarCombinesKindAndStorageFilters(signedIn: Bool, hasLocalHistory: Bool,
                                                        drawer: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "sidebar-filter-" + UUID().uuidString))
        let fixture = try AskTestFixture(localOnly: !signedIn, defaults: defaults)
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "main", title: "Main conversation", revision: 1,
                                     updatedAt: Date(), messages: [], kind: "chat"))
        await fixture.api.seed(.init(id: "main-task", title: "Main task", revision: 1,
                                     updatedAt: Date(), messages: [], kind: "work"))
        if hasLocalHistory {
            await fixture.localAPI.seed(.init(id: "local", title: "Local conversation", revision: 1,
                                              updatedAt: Date(), messages: [], kind: "chat"))
            await fixture.localAPI.seed(.init(id: "local-task", title: "Local task", revision: 1,
                                              updatedAt: Date(), messages: [], kind: "work"))
        }
        await fixture.model.refreshHistory()
        #expect(fixture.model.isSignedIn == signedIn)
        let window = host(AskConversationView(model: fixture.model).defaultAppStorage(defaults),
                          dark: true, size: CGSize(width: drawer ? 440 : 1100, height: 720))
        defer { window.close() }
        try await settle(window)
        if drawer {
            let toggle = try #require(find("ask.workspace.sidebar", in: window))
            _ = toggle.perform(NSSelectorFromString("accessibilityPerformPress"))
            try await settle(window)
        }
        for identifier in ["ask.history.storageFilter", "ask.history.kind.all", "ask.history.kind.chat", "ask.history.kind.work"] {
            let element = try #require(find(identifier, in: window))
            let frame = try #require(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            #expect(frame.width >= AskHistoryFilterBar.height - 0.5)
            #expect(window.frame.contains(frame), "Both filters stay visible, including in the drawer.")
        }
        #expect(find("ask.history.section.work", in: window) == nil)
        #expect(find("ask.history.section.chat", in: window) == nil)
        let content = try #require(window.contentView)
        let control = try #require(descendants(content).compactMap { $0 as? TFNativeMenuControl.MenuButton }
            .first { $0.accessibilityIdentifier() == "ask.history.storageFilter" })
        let name = "sidebar-signedIn-\(signedIn)-local-\(hasLocalHistory)-drawer-\(drawer)"
        try snapshot(window, name: name)
        let mainIds: Set<String> = ["main", "main-task"]
        let localIds: Set<String> = hasLocalHistory ? ["local", "local-task"] : []
        let storageIds: [AskHistoryFilter: Set<String>] = [
            .all: mainIds.union(localIds),
            .cloud: signedIn ? mainIds : [],
            .local: signedIn ? localIds : mainIds,
        ]
        let kindIds: [AskConversationKind: Set<String>] = [
            .chat: ["main", "local"], .work: ["main-task", "local-task"],
        ]
        for filter in [AskHistoryFilter.cloud, .local, .all] {
            let index = try #require(AskHistoryFilter.allCases.firstIndex(of: filter))
            let item = try #require(control.menu?.items[index])
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            try await settle(window)
            #expect(control.menu?.items[index].state == .on)
            for kind in [.work, .chat, nil] as [AskConversationKind?] {
                let tab = try #require(find("ask.history.kind." + (kind?.rawValue ?? "all"), in: window))
                _ = tab.perform(NSSelectorFromString("accessibilityPerformPress"))
                try await settle(window)
                let stored = try #require(storageIds[filter])
                let expected = kind.map { stored.intersection(kindIds[$0] ?? []) } ?? stored
                for row in fixture.model.conversations {
                    #expect((find("ask.history.row." + row.id, in: window) != nil) == expected.contains(row.id),
                            "Kind and storage filters must both update the production list: \(filter), \(String(describing: kind)), \(row.id)")
                }
                #expect(containsText(L("ask.history.empty"), in: window) == expected.isEmpty)
            }
            try snapshot(window, name: name + "-" + filter.rawValue)
        }
    }

    @Test func emptySidebarKeepsBothFiltersAvailable() async throws {
        let defaults = try #require(UserDefaults(suiteName: "sidebar-empty-" + UUID().uuidString))
        let fixture = try AskTestFixture(localOnly: true, defaults: defaults)
        defer { fixture.model.resetSession() }
        let window = host(AskConversationView(model: fixture.model).defaultAppStorage(defaults),
                          size: CGSize(width: 1100, height: 720))
        defer { window.close() }
        try await settle(window)
        for identifier in ["ask.history.storageFilter", "ask.history.kind.all", "ask.history.kind.chat", "ask.history.kind.work"] {
            #expect(find(identifier, in: window) != nil)
        }
        #expect(containsText(L("ask.history.empty"), in: window))
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

    private func containsText(_ text: String, in window: NSWindow) -> Bool {
        find(text, attribute: "accessibilityValue", in: window) != nil
            || find(text, attribute: "accessibilityLabel", in: window) != nil
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

private final class HeaderDragTestWindow: NSWindow {
    var dragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { dragEvent = event }
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
