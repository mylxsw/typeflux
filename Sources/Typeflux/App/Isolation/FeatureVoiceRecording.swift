import Foundation

struct FeatureVoiceRequest: Codable, Sendable {
    let session: UUID
    let owner: FeatureRole
    var event: AskVoiceHotkeyEvent?
}

struct FeatureVoiceUpdate: Codable, Sendable {
    let session: UUID
    var level: Float?
    var text: String?
    var final = false
    var audioStartedAt: TimeInterval?
}

/// Editors own insertion/cancellation; only the voice process owns audio and STT.
@MainActor
final class FeatureVoiceRecording: AskVoiceRecording {
    private static var clients: [UUID: WeakClient] = [:]
    private final class WeakClient {
        weak var value: FeatureVoiceRecording?
        init(_ value: FeatureVoiceRecording) {
            self.value = value
        }
    }

    private let owner: FeatureRole
    private let route: @MainActor (FeatureCommand, Duration) async throws -> Data
    init(owner: FeatureRole = FeatureProcess.role,
         route: @escaping @MainActor (FeatureCommand, Duration) async throws -> Data = { try await FeatureProcess.route(
             $0,
             timeout: $1
         ) }) {
        self.owner = owner; self.route = route
    }

    private var session = UUID()
    private var events: [AskVoiceHotkeyEvent] = []
    private var prepared = false
    private var active = false
    private var onLevel: (@MainActor (Float) -> Void)?
    private var onTranscript: (@MainActor (String, Bool) -> Void)?
    private(set) var audioStartedAt: TimeInterval?

    static func receive(_ update: FeatureVoiceUpdate) {
        guard let client = clients[update.session]?.value, client.active else { return }
        if let started = update.audioStartedAt, started.isFinite { client.audioStartedAt = started }
        if let level = update.level {
            client.onLevel?(level)
        }
        if let text = update.text {
            client.onTranscript?(text, update.final)
        }
    }

    func handleHotkey(_ event: AskVoiceHotkeyEvent) {
        if case .prepare = event {
            session = UUID(); audioStartedAt = nil; events = [event]; prepared = false; active = true
            Self.clients = Self.clients.filter { $0.value.value != nil }
            Self.clients[session] = WeakClient(self)
        } else if !prepared {
            events.append(event)
        } else {
            send(event)
        }
    }

    func observe(level: @escaping @MainActor (Float) -> Void, transcript: @escaping @MainActor (String, Bool) -> Void) {
        onLevel = level; onTranscript = transcript
    }

    func start() async throws {
        guard active, let first = events.first else { throw CancellationError() }
        let id = session
        _ = try await call("voice.prepare", event: first)
        guard active, session == id, !Task.isCancelled else { throw CancellationError() }
        prepared = true
        let pending = events.dropFirst(); events.removeAll()
        for event in pending {
            send(event)
        }
        let data = try await call("voice.start")
        guard active, session == id, !Task.isCancelled else { throw CancellationError() }
        audioStartedAt = try JSONDecoder().decode(TimeInterval?.self, from: data)
    }

    func transcribe() async throws -> String {
        let id = session
        let data = try await call("voice.transcribe", timeout: .seconds(180))
        guard active, session == id, !Task.isCancelled else { throw CancellationError() }
        active = false; prepared = false; Self.clients[id] = nil
        return try JSONDecoder().decode(String.self, from: data)
    }

    func cancel() async {
        guard active else { return }
        active = false
        _ = try? await call("voice.cancel")
        prepared = false; events.removeAll(); Self.clients[session] = nil
    }

    private func send(_ event: AskVoiceHotkeyEvent) {
        guard active, let payload = try? JSONEncoder().encode(FeatureVoiceRequest(
            session: session,
            owner: owner,
            event: event
        )) else { return }
        Task { [route] in _ = try? await route(
            .init(destination: .voice, action: "voice.event", payload: payload),
            .seconds(10)
        ) }
    }

    private func call(_ action: String, event: AskVoiceHotkeyEvent? = nil,
                      timeout: Duration = .seconds(30)) async throws -> Data {
        try await route(.init(
            destination: .voice,
            action: action,
            payload: JSONEncoder().encode(FeatureVoiceRequest(session: session, owner: owner, event: event))
        ), timeout)
    }
}

@MainActor
final class FeatureVoiceOwner {
    private var request: FeatureVoiceRequest?
    private var recorder: (any AskVoiceRecording)?
    private let activity: (@MainActor (Bool) -> Void)?
    private let makeRecorder: (@MainActor () -> any AskVoiceRecording)?
    init(makeRecorder: (@MainActor () -> any AskVoiceRecording)? = nil, activity: (@MainActor (Bool) -> Void)? = nil) {
        self.makeRecorder = makeRecorder
        self.activity = activity
    }

    private var watchdog: Task<Void, Never>?
    private var operation: Task<Data, Error>?
    private var lastLevel: TimeInterval = 0
    var editorOwner: FeatureRole? {
        request?.owner
    }

    func handle(_ command: FeatureCommand, workflow: WorkflowController? = nil) async throws -> Data {
        let value = try JSONDecoder().decode(FeatureVoiceRequest.self, from: command.payload)
        guard value.owner == .host || value.owner == .chat else { throw FeatureRPC.Failure.invalidMessage }
        if command.action == "voice.prepare" {
            guard request == nil, workflow?.isRecording != true else { throw FeatureRPC.Failure.busy }
            request = value
            let recorder: any AskVoiceRecording
            if let makeRecorder {
                recorder = makeRecorder()
            } else if let workflow {
                recorder = WorkflowComposerRecording(workflow)
            } else {
                request = nil; throw FeatureRPC.Failure.unavailable
            }
            self.recorder = recorder
            setActivity(true)
            if let event = value.event {
                recorder.handleHotkey(event)
            }
            recorder.observeStart { [weak self] started in
                guard let self, request?.session == value.session else { return }
                send(.init(session: value.session, audioStartedAt: started), to: value.owner)
            }
            recorder.observe(level: { [weak self] level in
                guard let self, request?.session == value.session else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastLevel >= 0.05 else { return }
                lastLevel = now
                send(.init(session: value.session, level: level), to: value.owner)
            }, transcript: { [weak self] text, final in
                guard let self, request?.session == value.session else { return }
                send(.init(session: value.session, text: text, final: final), to: value.owner)
            })
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(610)) } catch { return }
                await self?.cancel()
            }
            return Data()
        }
        guard request?.session == value.session, request?.owner == value.owner, let recorder else {
            // Cancellation may race a completed transcription; it remains idempotent.
            if command.action == "voice.cancel" {
                return Data()
            }
            throw FeatureRPC.Failure.unavailable
        }
        switch command.action {
        case "voice.start":
            let operation = Task<Data, Error> {
                try await recorder.start()
                return try JSONEncoder().encode(recorder.audioStartedAt)
            }
            self.operation = operation
            do { return try await operation.value }
            catch { await cancel(); throw error }
        case "voice.event":
            if let event = value.event {
                recorder.handleHotkey(event)
            }
            return Data()
        case "voice.transcribe":
            defer {
                if request?.session == value.session {
                    reset()
                }
            }
            let operation = Task<Data, Error> {
                try await JSONEncoder().encode(recorder.transcribe())
            }
            self.operation = operation
            return try await operation.value
        case "voice.cancel": await cancel(); return Data()
        default: throw FeatureRPC.Failure.invalidMessage
        }
    }

    func cancel() async {
        let current = recorder, id = request?.session, operation = operation
        operation?.cancel()
        await current?.cancel()
        _ = try? await operation?.value
        if request?.session == id {
            reset()
        }
    }

    private func reset() {
        setActivity(false)
        operation = nil; request = nil; recorder = nil; watchdog?.cancel(); watchdog = nil
    }

    private func setActivity(_ busy: Bool) {
        if let activity { activity(busy); return }
        guard FeatureProcess.enabled, FeatureProcess.role == .voice else { return }
        // Recording can end before file recognition/rewrite; keep a separate
        // source until the entire editor transaction and cleanup have ended.
        SemanticFileSearchService.shared.remoteSend("busy.voiceEditor", value: FeatureForegroundActivity(busy: busy))
    }

    private func send(_ update: FeatureVoiceUpdate, to owner: FeatureRole) {
        guard let payload = try? JSONEncoder().encode(update) else { return }
        FeatureProcess.send(.init(destination: owner, action: "voice.update", payload: payload))
    }
}
