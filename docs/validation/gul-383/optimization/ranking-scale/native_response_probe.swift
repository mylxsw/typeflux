import AppKit
import Metal
import MetalKit
import QuartzCore
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Darwin

// A standalone AppKit event loop measures the host's response while another process indexes.
// Only this probe's generated event IDs and numeric timestamps are recorded.
final class Presentations: @unchecked Sendable {
    let lock = NSLock()
    var rows: [Int64: [String: Any]] = [:]
    func sent(_ id: Int64, kind: String, planned: Double, context: [String: Bool]) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { rows[id] = ["id": id, "kind": kind, "sent_uptime": now,
            "planned_send_uptime": planned, "producer_delay_ms": (now-planned)*1000,
            "input_to_present_ms": NSNull(), "missing": true, "window_context_at_start": context] }
    }
    func handled(_ id: Int64, at time: Double, context: [String: Bool]) {
        lock.withLock {
            guard let start = rows[id]?["sent_uptime"] as? Double else { return }
            rows[id]?["input_to_handler_ms"] = (time - start) * 1000
            rows[id]?["window_context_at_handler"] = context
            if let planned = rows[id]?["planned_send_uptime"] as? Double {
                rows[id]?["planned_to_handler_ms"] = (time-planned)*1000
            }
            rows[id]?["missing"] = false
        }
    }
    func gpuCompleted(_ id: Int64, at time: Double, status: Int) {
        lock.withLock {
            guard let start = rows[id]?["sent_uptime"] as? Double else { return }
            rows[id]?["input_to_gpu_complete_ms"] = time.isFinite && time >= start ? (time - start) * 1000 as Any : NSNull()
            rows[id]?["gpu_status"] = status
        }
    }
    func presented(_ id: Int64, at time: Double) {
        lock.withLock {
            guard let start = rows[id]?["sent_uptime"] as? Double else { return }
            rows[id]?["input_to_present_ms"] = time.isFinite && time >= start ? (time - start) * 1000 as Any : NSNull()
            rows[id]?["presented_time"] = time
        }
    }
    func windowServer(_ id: Int64, displayed: Double, captured: Double) {
        lock.withLock {
            guard let start = rows[id]?["sent_uptime"] as? Double, displayed >= start,
                  rows[id]?["input_to_windowserver_ms"] == nil else { return }
            rows[id]?["input_to_windowserver_ms"] = (displayed - start) * 1000
            rows[id]?["windowserver_display_uptime"] = displayed
            rows[id]?["input_to_capture_callback_ms"] = (captured - start) * 1000
            if let planned = rows[id]?["planned_send_uptime"] as? Double {
                rows[id]?["planned_to_windowserver_ms"] = (displayed-planned)*1000
            }
        }
    }
    func report() -> [[String: Any]] { lock.withLock { rows.sorted { $0.key < $1.key }.map(\.value) } }
    var handlers: Int { lock.withLock { rows.values.filter { $0["missing"] as? Bool == false }.count } }
    var completed: Int { lock.withLock { rows.values.filter { $0["gpu_status"] as? Int == Int(MTLCommandBufferStatus.completed.rawValue) }.count } }
}

/// Event production must not share the UI queue whose stalls it measures.
final class EventProducer: @unchecked Sendable {
    let queue = DispatchQueue(label: "typeflux.validation.input-producer", qos: .userInteractive)
    let timer: DispatchSourceTimer
    let samples: Presentations, start: Double, duration: Double
    let events: [[CGEvent]], context: [String: Bool]
    let progress: @Sendable () -> Void, completion: @Sendable () -> Void
    var serial: Int64 = 0
    init(samples: Presentations, start: Double, duration: Double, events: [[CGEvent]],
         context: [String: Bool], progress: @escaping @Sendable () -> Void,
         completion: @escaping @Sendable () -> Void) {
        self.samples=samples;self.start=start;self.duration=duration;self.events=events;self.context=context
        self.progress=progress;self.completion=completion
        timer=DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now()+1,repeating: 1,leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() };timer.resume()
    }
    private func tick() {
        let now=ProcessInfo.processInfo.systemUptime
        let due=max(0,min(Int(duration.rounded(.up))-1,Int(floor(now-start))))
        while serial<Int64(due) {
            serial+=1
            let kind=Int(serial%3), name=["keyboard","mouse","window"][kind]
            guard let down=events[kind][0].copy(),let up=events[kind][1].copy() else { continue }
            let timestamp=CGEventTimestamp(ProcessInfo.processInfo.systemUptime*1e9)
            down.timestamp=timestamp;up.timestamp=timestamp
            down.setIntegerValueField(.eventSourceUserData,value: serial)
            samples.sent(serial,kind: name,planned: start+Double(serial),context: context)
            down.postToPid(ProcessInfo.processInfo.processIdentifier);up.postToPid(ProcessInfo.processInfo.processIdentifier)
        }
        if now-start>=duration { timer.cancel();completion();return }
        if serial%5==0 { progress() }
    }
    func stop() async {
        timer.cancel()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    deinit { timer.cancel() }
}

/// Only generated event bits are drawn and sampled. No frame/image or unrelated window is retained.
final class EventStamp: NSView {
    var eventID: Int64 = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        for bit in 0..<16 {
            (eventID & (1 << bit) == 0 ? NSColor.black : NSColor.white).setFill()
            NSRect(x: CGFloat(bit)*bounds.width/16, y: bounds.height*0.2,
                   width: bounds.width/16+1, height: bounds.height*0.6).fill()
        }
    }
}

final class WindowFrames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let samples: Presentations
    @MainActor private var capture: SCStream?
    let queue = DispatchQueue(label: "typeflux.validation.window-frames", qos: .utility)
    private let lock = NSLock()
    private var failure: Int?
    var errorCode: Int? { lock.withLock { failure } }
    init(samples: Presentations) { self.samples = samples }
    @MainActor func start(windowID: CGWindowID, size: CGSize) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw NSError(domain: "ProbeCapture", code: 1) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.windowID == windowID && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }) else { throw NSError(domain: "ProbeCapture", code: 2) }
        let config = SCStreamConfiguration()
        config.width = Int(size.width); config.height = Int(size.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.queueDepth = 2
        config.showsCursor = false; config.scalesToFit = true; config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        capture = stream; try await stream.startCapture()
    }
    @MainActor func stop() async {
        if let capture { try? await capture.stopCapture() }
        capture = nil
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { failure = (error as NSError).code }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        autoreleasepool {
            guard type == .screen, let metadata = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let info = metadata.first,
                let status = info[.status] as? Int, status == SCFrameStatus.complete.rawValue,
                let ticks = info[.displayTime] as? UInt64, ticks > 0,
                let buffer = sample.imageBuffer else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            guard width >= 64, height >= 64 else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
            var id: Int64 = 0
            for bit in 0..<16 {
                let x = min(width-1, Int((Double(bit)+0.5)*Double(width)/16)), offset = (height/2)*stride+x*4
                let values = [Int(bytes[offset]),Int(bytes[offset+1]),Int(bytes[offset+2])]
                // Reject colors/antialiasing/window decorations instead of inventing an ID.
                guard values.max()! < 40 || values.min()! > 215 else { return }
                if values.min()! > 215 { id |= 1 << bit }
            }
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            let displayed = Double(ticks)*Double(timebase.numer)/Double(timebase.denom)/1e9
            samples.windowServer(id, displayed: displayed, captured: ProcessInfo.processInfo.systemUptime)
        }
    }
}

final class ResponseView: MTKView, MTKViewDelegate {
    var pendingInput: (Int64, Double)?
    let metalDevice: MTLDevice
    let commands: MTLCommandQueue
    let samples: Presentations
    var toggled = false
    let stamp = EventStamp()
    override var acceptsFirstResponder: Bool { true }
    init(samples: Presentations) {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        self.metalDevice = device; self.commands = commands; self.samples = samples
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 220), device: device)
        isPaused = true; enableSetNeedsDisplay = true; framebufferOnly = true; delegate = self
        stamp.frame = bounds; stamp.autoresizingMask = [.width,.height]; addSubview(stamp)
    }
    required init(coder: NSCoder) { fatalError("Programmatic view only") }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123, let window { var frame = window.frame; frame.size.width += toggled ? -1 : 1; window.setFrame(frame, display: true) }
        respond(event)
    }
    override func mouseDown(with event: NSEvent) { respond(event) }
    func respond(_ event: NSEvent) {
        guard let cg = event.cgEvent else { return }
        let id = cg.getIntegerValueField(.eventSourceUserData), delivered = ProcessInfo.processInfo.systemUptime
        stamp.eventID = id; stamp.needsDisplay = true; stamp.displayIfNeeded()
        samples.handled(id, at: delivered, context: ["visible": window?.isVisible == true,
            "on_active_space": window?.isOnActiveSpace == true,
            "occluded": window?.occlusionState.contains(.visible) != true,
            "key": window?.isKeyWindow == true])
        pendingInput = (id, delivered); draw()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let (id, _) = pendingInput else { return }; pendingInput = nil
        guard let drawable = currentDrawable, let buffer = commands.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        toggled.toggle(); pass.colorAttachments[0].clearColor = MTLClearColor(red: toggled ? 0.08 : 0.18, green: 0.2, blue: 0.25, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding(); let samples = samples
        drawable.addPresentedHandler { value in samples.presented(id, at: value.presentedTime) }
        buffer.addCompletedHandler { value in samples.gpuCompleted(id, at: value.gpuEndTime, status: Int(value.status.rawValue)) }
        buffer.present(drawable); buffer.commit()
    }
}

@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    let samples = Presentations(), output: URL, duration: Double
    var window: NSWindow!, view: ResponseView!, producer: EventProducer?
    var start = 0.0, wall = 0.0
    var succeeded = false
    private var stopping = false
    var frames: WindowFrames?
    init(output: URL, duration: Double) { self.output = output; self.duration = duration }
    func applicationDidFinishLaunching(_ notification: Notification) {
        view = ResponseView(samples: samples)
        window = NSWindow(contentRect: NSRect(x: 180, y: 200, width: 480, height: 220), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating
        window.title = "Typeflux indexing response probe"; window.contentView = view
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); NSApp.activate(ignoringOtherApps: true)
        let frames = WindowFrames(samples: samples); self.frames = frames
        Task { @MainActor [self] in
            do {
                try await frames.start(windowID: CGWindowID(window.windowNumber), size: window.frame.size)
                let events = try ["keyboard","mouse","window"].map { try templates($0) }
                start = ProcessInfo.processInfo.systemUptime; wall = Date().timeIntervalSince1970
                producer=EventProducer(samples: samples,start: start,duration: duration,events: events,
                    context: ["visible":window.isVisible,"on_active_space":window.isOnActiveSpace,
                        "occluded":!window.occlusionState.contains(.visible),"key":window.isKeyWindow],
                    progress: { [weak self] in Task { @MainActor in self?.write(complete: false) } },
                    completion: { [weak self] in Task { @MainActor in
                        guard let self else { return };self.succeeded=true;self.write(complete: true);self.stop()
                    } })
                write(complete: false)
                if let delay=Double(ProcessInfo.processInfo.environment["TYPEFLUX_PROBE_STALL_MS"] ?? ""),delay>0,delay.isFinite {
                    DispatchQueue.main.asyncAfter(deadline: .now()+3.1) { Thread.sleep(forTimeInterval: delay/1000) }
                }
            } catch { fputs("Own-window capture unavailable\n", stderr); stop() }
        }
    }
    func templates(_ kind: String) throws -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState), down: CGEvent?, up: CGEvent?
        if kind == "mouse" {
            let point = window.convertPoint(toScreen: .init(x: 200, y: 100)); let location = CGPoint(x: point.x, y: (NSScreen.main?.frame.height ?? 900) - point.y)
            down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 100), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)?.cgEvent
            up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 200, y: 100), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)?.cgEvent
            down?.location = location; up?.location = location
        } else {
            down = CGEvent(keyboardEventSource: source, virtualKey: kind == "window" ? 123 : 0, keyDown: true)
            up = CGEvent(keyboardEventSource: source, virtualKey: kind == "window" ? 123 : 0, keyDown: false)
        }
        guard let down, let up else { throw NSError(domain: "ProbeInput",code: 1) }
        if kind == "mouse" {
            down.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            down.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        }
        return [down,up]
    }
    func write(complete: Bool) {
        let rows = samples.report(), value: [String: Any] = ["started_unix": wall, "started_uptime": start, "duration_seconds": ProcessInfo.processInfo.systemUptime - start, "complete": complete, "presentation_available": rows.contains { $0["input_to_present_ms"] is Double }, "inputs": rows, "handler_count": samples.handlers, "window_visible": window.isVisible, "window_occluded": !window.occlusionState.contains(.visible), "window_key": window.isKeyWindow, "layer_width": view.bounds.width, "layer_height": view.bounds.height, "display_active": CGDisplayIsActive(CGMainDisplayID()) != 0, "display_asleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0, "pid": ProcessInfo.processInfo.processIdentifier, "scope": "Dedicated AppKit application using NSApplication.run; generated CGEvent.postToPid keyboard/mouse/window-resize events -> native NSResponder -> CAMetalDrawable.presentedTime. Actual GPU completion is recorded separately as substitute evidence when presentedTime is zero. Zero presentedTime stays null and is never an onscreen presentation claim. No synthetic test event pump, search-result mocks, global keystroke contents or privileged metrics."]
        var report = value
        report["windowserver_presentation_available"] = rows.contains { $0["input_to_windowserver_ms"] is Double }
        report["capture_error_code"] = frames?.errorCode as Any? ?? NSNull()
        report["producer"] = "Independent user-interactive serial dispatch timer; immutable event templates copied per send. Planned send time, actual send time and producer delay are separate. Handler-time window context is authoritative; start context is retained separately. Coalesced timer firings retain every planned event ID. No main-thread sender or test event pump."
        report["calibration_stall_ms"] = Double(ProcessInfo.processInfo.environment["TYPEFLUX_PROBE_STALL_MS"] ?? "") as Any? ?? NSNull()
        report["windowserver_scope"] = "ScreenCaptureKit captures this process's own visible window only, queueDepth=2. Decode its 16 black/white generated event-ID bars; associate only complete frames carrying that exact ID and displayTime >= input time. displayTime is the WindowServer frame display timestamp (mach absolute time converted using mach_timebase_info). No image, other application content, or global input is retained. This is a compositor observation, not a physical monitor scanout fence. Metal presentedTime remains separate."
        do { try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: output, options: .atomic) }
        catch { succeeded = false; fputs("Could not write numeric probe report\n", stderr); stop() }
    }
    func stop() {
        guard !stopping else { return }; stopping = true
        Task { @MainActor in
            await producer?.stop();await frames?.stop(); window.close(); NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
        }
    }
}

let args = CommandLine.arguments
guard args.count == 3, let duration = Double(args[2]), duration.isFinite,
      duration > 0, duration < 65535 else { exit(64) }
let code: Int32 = MainActor.assumeIsolated {
    let application = NSApplication.shared, probe = Probe(output: URL(fileURLWithPath: args[1]), duration: duration)
    application.delegate = probe; application.setActivationPolicy(.regular); application.run()
    return probe.succeeded ? 0 : 2
}
exit(code)
