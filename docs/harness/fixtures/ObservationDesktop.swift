import AppKit

// Standalone controlled target. It records mouse delivery without changing its
// accessibility tree, and exits after 45 seconds even if the harness crashes.
final class Canvas: NSView {
    let log: URL
    init(log: URL) {
        self.log = log
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Typeflux drag fixture")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        ("Typeflux controlled drag target" as NSString).draw(at: NSPoint(x: 30, y: 180), withAttributes: [.foregroundColor: NSColor.labelColor])
    }
    func record(_ name: String) {
        let previous = (try? Data(contentsOf: log)) ?? Data()
        try? (previous + Data((name + "\n").utf8)).write(to: log, options: .atomic)
    }
    override func mouseDown(with event: NSEvent) { record("down") }
    override func mouseDragged(with event: NSEvent) { record("drag") }
    override func mouseUp(with event: NSEvent) { record("up") }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let canvas = Canvas(log: URL(fileURLWithPath: CommandLine.arguments[1]))
        window.contentView = canvas
        window.title = "Typeflux controlled observation fixture"
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in NSApp.terminate(nil) }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
