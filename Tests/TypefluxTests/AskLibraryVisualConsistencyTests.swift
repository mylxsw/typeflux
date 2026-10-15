import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Library visual consistency", .serialized, .exclusiveUIState)
@MainActor
struct AskLibraryVisualConsistencyTests {
    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func nativeLibrariesShareColumnsAndKeepActionsReachable(style: InterfaceStyle) async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.interfaceStyle = style
            settings.appearanceMode = .dark
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let card = AskWordCard(headword: "Shipping Velocity",
                senses: [.init(pos: "n.", meanings: ["交付速度；软件功能从开发到上线的效率和速度",
                                                      "发货速度；商品出库配送的快慢",
                                                      "（口语）团队推进并交付工作的节奏"])],
                examples: [.init(source: "The team improved its **shipping velocity** by automating the release pipeline.",
                                 target: "该团队通过自动化发布流程提高了交付速度。")],
                synonyms: ["delivery speed", "release cadence", "deployment frequency", "throughput", "output rate"])
            let lookup = AskWordBookLookup(headword: card.headword, source: "en", target: "zh-Hans", card: card, model: "AI")
            let words = makeTestWordBook()
            try words.record(lookup, at: .now, counts: true)
            for (word, meaning) in [("简洁", "concise; succinct; brief and to the point"),
                                     ("渐变", "to change gradually; to evolve slowly"),
                                     ("狗粮", "dog food; public display of affection")] {
                try words.record(AskWordBookLookup(headword: word, source: "zh-Hans", target: "en", translation: meaning),
                             at: .now.addingTimeInterval(-60), counts: true)
            }
            let wordController = AskWordBookWindowController()
            let wordFrameName = "wordbook-visual-frame-\(UUID().uuidString)"
            wordController.frameAutosaveName = wordFrameName
            defer { NSWindow.removeFrame(usingName: wordFrameName) }
            wordController.configure(store: words, dictionary: AskTestWordLookup(answer: .card(card)),
                                     settings: settings, askAI: { _ in }, modelName: { "AI" })
            wordController.show(selecting: lookup.key)
            let wordWindow = try #require(wordController.window)
            let wordModel = try #require(wordController.model)
            defer { wordWindow.close() }
            try await Task.sleep(for: .milliseconds(180))
            let defaultHost = try #require(wordWindow.contentView)
            let defaultLayout = AskLibraryLayout(width: defaultHost.bounds.width)
            #expect(defaultLayout.sidebarInline, "the actual default window opens with its sidebar visible")

            let notes = makeTestNotes()
            let note = AskNote(title: "解释 · hell cat",
                body: "“地狱猫”（hell cat）通常指两种常见意思：\n\n1. **一种绰号**：形容凶猛、难以对付的人或动物。\n2. **一种战斗机**：二战美国海军的 **F6F Hellcat**。",
                command: "解释", keyword: "ex", input: "hell cat", sourceApp: "Google Chrome",
                createdAt: .now, updatedAt: .now)
            try notes.save(note)
            let noteController = AskNotesWindowController()
            noteController.configure(store: notes, settings: settings, askAI: { _ in }) { NSAppearance(named: .darkAqua) }
            noteController.show(selecting: note.id)
            let noteWindow = try #require(noteController.window)
            defer { noteWindow.close() }

            for width in [1320, 1120, 1090, 1100, 900, 720, 1440, 1120] {
                let size = NSSize(width: width, height: 620)
                let layout = AskLibraryLayout(width: CGFloat(width))
                wordWindow.setContentSize(size)
                noteWindow.setContentSize(size)
                wordWindow.setFrameOrigin(NSPoint(x: 80, y: 80))
                noteWindow.setFrameOrigin(NSPoint(x: 80, y: 80))
                try await Task.sleep(for: .milliseconds(180))
                if width == 1320 || width == 1120 || width == 720 {
                    try await capture(wordWindow, "wordbook-\(style.rawValue)-\(width)-dark.png", hiding: noteWindow)
                    try await capture(noteWindow, "notebook-\(style.rawValue)-\(width)-dark.png", hiding: wordWindow)
                }
                let host = try #require(wordWindow.contentView)
                let filter = try element("ask.wordBook.search", in: host)
                let noteFilter = try element("ask.notes.search", in: try #require(noteWindow.contentView))
                #expect(abs(filter.frame.minX - noteFilter.frame.minX) < 1,
                        "search fields follow the same sidebar and list geometry")
                #expect(abs(filter.frame.height - noteFilter.frame.height) < 1)
                let detailStart = wordWindow.frame.minX + layout.sidebarWidth + layout.listWidth
                for label in [L("ask.plugin.action.copyDefinition"), L("ask.quick.askAI"),
                              L("ask.plugin.action.regenerate"), L("ask.wordBook.delete")] {
                    let button = try button(label, in: host)
                    #expect(button.frame.minX >= detailStart && button.frame.maxX <= wordWindow.frame.maxX,
                            "floating actions stay inside the detail column")
                    #expect(button.frame.minY >= wordWindow.frame.minY + 12
                            && button.frame.maxY <= wordWindow.frame.minY + 60,
                            "both libraries keep actions at the bottom")
                }
                let lookupField = try element("ask.wordBook.lookup", in: host)
                #expect(lookupField.frame.minX >= detailStart && lookupField.frame.width > 80)
                #expect(wordModel.selectedKey == lookup.key, "selection survives every collapse boundary")
                if !layout.sidebarInline {
                    let toggle = try button(L("ask.sidebar.toggle"), in: host)
                    #expect(toggle.frame.width >= 20)
                }
            }

            wordWindow.setContentSize(NSSize(width: 720, height: 480))
            wordWindow.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            var copied: String?
            wordModel.copy = { copied = $0 }
            let host = try #require(wordWindow.contentView)
            try click(button(L("ask.plugin.action.copyDefinition"), in: host), in: wordWindow)
            try await SettingsBehaviorTestSupport.wait { copied != nil }
            #expect(copied?.contains("交付速度") == true, "the floating compact copy button works")
            let direction = try button(L("ask.wordBook.lookup.direction"), in: host)
            try click(direction, in: wordWindow)
            #expect(wordModel.targetPreset != nil, "lookup direction stays clickable at minimum size")
            try click(button(L("ask.sidebar.toggle"), in: host), in: wordWindow)
            try await SettingsBehaviorTestSupport.wait { !(wordWindow.childWindows ?? []).isEmpty }
            let popup = try #require(wordWindow.childWindows?.first)
            let shelf = try button(wordModel.title(of: .starred),
                                                               in: try #require(popup.contentView))
            try shelf.press()
            try await SettingsBehaviorTestSupport.wait { wordModel.shelf == .starred }
            try await SettingsBehaviorTestSupport.wait { (wordWindow.childWindows ?? []).isEmpty }

            for window in [wordWindow, noteWindow] {
                window.appearance = NSAppearance(named: .aqua)
            }
            wordModel.shelf = .all
            await wordModel.reveal(lookup.key)
            try await capture(wordWindow, "wordbook-\(style.rawValue)-720-light.png", hiding: noteWindow)
            noteWindow.setContentSize(NSSize(width: 720, height: 480))
            try await capture(noteWindow, "notebook-\(style.rawValue)-720-light.png", hiding: wordWindow)
        }
    }

    private func element(_ identifier: String, in host: NSView) throws -> SettingsBehaviorTestSupport.Element {
        let placeholder: String? = switch identifier {
        case "ask.wordBook.search": L("ask.wordBook.search")
        case "ask.wordBook.lookup": L("ask.wordBook.lookup.placeholder")
        case "ask.notes.search": L("ask.notes.search")
        default: nil
        }
        let items = elements(in: host)
        return try #require(items.first {
            if $0.value("accessibilityIdentifier") as? String == identifier { return true }
            guard let placeholder else { return false }
            return ($0.object as? NSTextField)?.placeholderString == placeholder
                || $0.value("accessibilityPlaceholderValue") as? String == placeholder
        }, "Missing library control: \(identifier). Fields: \(items.filter { $0.role == NSAccessibility.Role.textField.rawValue }.map { $0.text })")
    }

    private func button(_ label: String, in host: NSView) throws -> SettingsBehaviorTestSupport.Element {
        try #require(elements(in: host).first {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label == label
        }, "Missing library button: \(label)")
    }

    /// Transparent hosting views expose some native controls through their subviews.
    private func elements(in host: NSView) -> [SettingsBehaviorTestSupport.Element] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> [SettingsBehaviorTestSupport.Element] {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let item = SettingsBehaviorTestSupport.Element(object: object)
            let children = (item.value("accessibilityChildren") as? [Any] ?? []).flatMap(walk)
            let subviews = (object as? NSView)?.subviews.flatMap(walk) ?? []
            return [item] + children + subviews
        }
        return walk(host)
    }

    private func click(_ element: SettingsBehaviorTestSupport.Element, in window: NSWindow) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    private func capture(_ window: NSWindow, _ name: String, hiding other: NSWindow) async throws {
        other.orderOut(nil)
        defer { other.orderFront(nil) }
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_LIBRARY_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent(name).path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
