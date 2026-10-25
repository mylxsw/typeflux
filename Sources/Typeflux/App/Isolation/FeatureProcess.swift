import AppKit
import Darwin
import Foundation
import OSLog

enum FeatureRole: String, Codable, Sendable, CaseIterable {
    case host, chat, launcher, screenshot, clipboard, shortcuts, settings, voice, ring, notes, wordBook, monitor, help, translation, background

    /// Logical destinations stay stable in diagnostics and saved commands.
    var processOwner: FeatureRole {
        switch self {
        case .chat, .voice, .screenshot, .background: self
        default: .host
        }
    }

    func owns(_ destination: FeatureRole) -> Bool { self == destination.processOwner }

    static let processRoles: [FeatureRole] = [.host, .voice, .chat, .screenshot, .background]
}

struct FeatureRoutedCommand: Codable, Sendable {
    let command: FeatureCommand
    let timeoutMilliseconds: Int64
    init(command: FeatureCommand, timeout: Duration) {
        self.command = command
        timeoutMilliseconds = timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000
    }
}

struct FeatureCommand: Codable, Sendable {
    let destination: FeatureRole
    let action: String
    var payload: Data = Data()
    var latency: ShortcutLatencyTrace? = nil
}

/// Installed only by the real application entry point. Injected test controllers
/// continue to use their in-process dependencies and never launch applications.
@MainActor
enum FeatureProcess {
    private nonisolated static let configuration = FeatureRuntimeConfiguration()
    nonisolated static var role: FeatureRole { configuration.value.role }
    nonisolated static var enabled: Bool { configuration.value.enabled }
    private(set) static var peer: FeatureRPC?
    private(set) static var supervisor: FeatureSupervisor?
    static let immediateWarmRoles: [FeatureRole] = [.voice, .background]
    static let deferredWarmRoles: [FeatureRole] = [.screenshot]
    static var handle: (@MainActor (FeatureCommand) async throws -> Data)?
    private static var ready: Task<Void, Error>?
    private static var deferredWarmup: Task<Void, Never>?
    private static var services: Task<Void, Never>?
    private static var preferencesUpdate: Task<Void, Never>?
    private static var observers: [NSObjectProtocol] = []
    private static var preferences: NSDictionary?
    private static var applyingNotification = false
    nonisolated static let sharedNotifications: [Notification.Name] = [.askNotesDidChange, .askWordBookDidChange, .historyStoreDidChange, .clipboardHistoryDidChange, .askLauncherInputHistoryDidChange, .vocabularyStoreDidChange]
    private static var parentMonitor: DispatchSourceTimer?

    static func install(arguments: [String]) throws {
        if arguments.isEmpty { configuration.install(.host); return }
        guard arguments.first == "--feature-process" else { configuration.install(.host); return }
        guard arguments.count == 4, let selected = FeatureRole(rawValue: arguments[1]), selected != .host, selected.processOwner == selected,
              arguments[2] == "--ipc-fd", arguments[3] == "100" else { throw FeatureRPC.Failure.invalidMessage }
        configuration.install(selected)
        peer = try FeatureRPC(descriptor: 100)
        try TypefluxDataDirectories.inheritFeatureLayout(environment: ProcessInfo.processInfo.environment)
        let parent = getppid()
        guard parent > 1 else { throw FeatureRPC.Failure.unavailable }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(parent, &path, UInt32(path.count))
        let parentURL = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        guard FeatureIsolationProbe.enabled || (length > 0 && parentURL == AskFileReader.executableURL.resolvingSymlinksInPath()) else {
            throw FeatureRPC.Failure.unavailable
        }
        UserDefaults.standard.synchronize()
        FeatureIsolationProbe.installCoverageExit()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        let lifetime = FeatureParentLifetime(parent: parent)
        timer.setEventHandler { lifetime.check() }
        timer.resume()
        parentMonitor = timer
    }

    static func configure(api: any AskAPI, cache: any AskCaching = RecoveringAskConversationCache(), preparation: Task<Void, Never>? = nil) {
        guard enabled else { return }
        services = preparation
        if role == .host, UserDefaults.standard.string(forKey: "ask.deviceId") == nil {
            UserDefaults.standard.set(UUID().uuidString, forKey: "ask.deviceId")
            UserDefaults.standard.synchronize()
        }
        preferences = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        observers.append(SettingsChangeObserver.observe {
            let next = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
            guard preferences?.isEqual(next) != true else { return }
            preferences = next
            preferencesUpdate?.cancel()
            preferencesUpdate = Task {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                send(.init(destination: .host, action: "preferences"))
            }
        })
        for name in sharedNotifications {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    guard !applyingNotification else { return }
                    send(.init(destination: .host, action: "changed", payload: Data(notification.name.rawValue.utf8)))
                }
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { event in
                let focus = FeatureFocus(role: role, focused: event.name == NSWindow.didBecomeKeyNotification,
                                         uptime: ProcessInfo.processInfo.systemUptime)
                if let data = try? JSONEncoder().encode(focus) { send(.init(destination: .host, action: "focus", payload: data)) }
            })
        }
        if let peer {
            ready = Task {
                await peer.start { method, payload in
                    guard method == "ui" else { throw FeatureRPC.Failure.invalidMessage }
                    let command = try JSONDecoder().decode(FeatureCommand.self, from: payload)
                    ShortcutLatency.record(.targetWireReceived, trace: command.latency)
                    return try await receive(command)
                }
                let snapshot: FeatureAuth = try await peer.call("bootstrap", FeatureRPC.Empty())
                await preparation?.value
                try Task.checkCancellation()
                snapshot.apply()
            }
        } else {
            supervisor = FeatureSupervisor(api: api, cache: cache, auth: FeatureAuth.capture(), preparation: preparation)
            for role in immediateWarmRoles {
                Task { _ = try? await supervisor?.route(.init(destination: role, action: "ping"), timeout: .seconds(30)) }
            }
            // Avoid competing with the initial warmup. Ping never presents a window
            // or registers shortcuts, and sequential startup bounds additional work.
            if !FeatureIsolationProbe.enabled, !deferredWarmRoles.isEmpty {
                let warmSupervisor = supervisor
                deferredWarmup = Task {
                    await preparation?.value
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    for role in deferredWarmRoles {
                        guard !Task.isCancelled else { return }
                        _ = try? await warmSupervisor?.route(.init(destination: role, action: "ping"), timeout: .seconds(30))
                    }
                }
            }
            for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh, .authSubscriptionDidChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        let snapshot = FeatureAuth.capture()
                        Task { await supervisor?.updateAuth(snapshot) }
                    }
                })
            }

        }
    }

    static func preventWarmup() {
        deferredWarmup?.cancel(); deferredWarmup = nil
        preferencesUpdate?.cancel(); preferencesUpdate = nil
    }

    static func waitForServices() async { await services?.value }

    nonisolated static func owns(_ destination: FeatureRole) -> Bool { !enabled || role.owns(destination) }

    static func route(_ command: FeatureCommand, timeout: Duration = .seconds(10)) async throws -> Data {
        guard timeout > .zero, timeout <= .seconds(180) else { throw FeatureRPC.Failure.invalidMessage }
        if command.destination.processOwner == role, role != .host { return try await receive(command) }
        if let peer {
            return try await peer.call("route", FeatureRoutedCommand(command: command, timeout: timeout), timeout: timeout)
        }
        guard let supervisor else { throw FeatureRPC.Failure.unavailable }
        return try await supervisor.route(command, timeout: timeout)
    }

    static func dispatch(_ command: FeatureCommand) async throws {
        guard let peer else { _ = try await route(command); return }
        let _: FeatureRPC.Empty = try await peer.call("dispatch", command)
    }

    private static let sender = FeatureCommandSender(route: { try await route($0) })

    nonisolated static func send(_ command: FeatureCommand) {
        var command = command
        command.latency = command.latency ?? ShortcutLatency.current
        Task { @MainActor in sender.send(command) }
    }

    static func receive(_ command: FeatureCommand) async throws -> Data {
        try await ShortcutLatency.$current.withValue(command.latency) {
            try await receiveTraced(command)
        }
    }

    private static func receiveTraced(_ command: FeatureCommand) async throws -> Data {
        if command.action == "resourceSnapshot" { return try JSONEncoder().encode(FeatureResourceSnapshot.capture()) }
        ShortcutLatency.record(.targetReceived)
        if command.action == "changed" {
            let name = Notification.Name(String(decoding: command.payload, as: UTF8.self))
            guard sharedNotifications.contains(name) else { throw FeatureRPC.Failure.invalidMessage }
            applyingNotification = true
            defer { applyingNotification = false }
            NotificationCenter.default.post(name: name, object: nil)
            return Data()
        }
        if command.action == "settings" {
            UserDefaults.standard.synchronize()
            preferences = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        }
        if command.action == "auth" {
            try JSONDecoder().decode(FeatureAuth.self, from: command.payload).apply()
            return Data()
        }
        ShortcutLatency.record(.readinessStarted)
        // Cleanup must remain reachable when bootstrap failed or is still waiting
        // on module startup. A failed readiness task otherwise poisons every quit.
        if command.action == "shutdown" {
            services?.cancel()
            ready?.cancel()
        } else {
            try await ready?.value
        }
        ShortcutLatency.record(.readinessFinished)
        guard command.destination.processOwner == role, let handle else { throw FeatureRPC.Failure.unavailable }
        ShortcutLatency.record(.handlerStarted)
        do {
            let result = try await handle(command)
            ShortcutLatency.record(.handlerFinished)
            return result
        } catch {
            ShortcutLatency.record(.failed)
            throw error
        }
    }
}

/// The supervisor has no AppKit dependency and never waits synchronously for UI.
/// Each isolated owner has its own socket, queue, request budget and child process.
actor FeatureSupervisor {
    private struct Child {
        let peer: FeatureRPC
        let stateSender: FeatureCommandSender
        let process: Task<Void, Never>
    }
    private let executableURL: URL
    private let environment: [String: String]
    private let api: any AskAPI
    private let cache: any AskCaching
    private let preparation: Task<Void, Never>?
    private var auth: FeatureAuth
    private var children: [FeatureRole: Child] = [:]
    private var starting: [FeatureRole: Task<Child, Error>] = [:]
    private var stopped = false
    private var launches: [FeatureRole: [ContinuousClock.Instant]] = [:]
    private var channelGenerations: [FeatureRole: UUID] = [:]
    private var liveChannels: Set<UUID> = []
    private var callsInFlight: [UUID: Int] = [:]
    private var routesInFlight: [FeatureRole: Int] = [:]
    private var focusedRole: FeatureRole = .host
    private var focusUptime: TimeInterval = 0
    private var voiceOwner: FeatureRole?
    private var pendingStatuses: [FeatureRole: FeatureStatus] = [:]
    private var moduleStates: [FeatureRole: [ModuleID: ModuleHealth]] = [:]
    private var mirrorScheduled = false
    private var executionOwners: [String: FeatureExecutionOwner] = [:]

    init(api: any AskAPI, cache: any AskCaching, auth: FeatureAuth, preparation: Task<Void, Never>? = nil,
         executableURL: URL = AskFileReader.executableURL,
         environment: [String: String]? = nil) {
        self.api = api; self.cache = cache; self.auth = auth; self.preparation = preparation
        self.executableURL = executableURL
        var values = ProcessInfo.processInfo.environment
        values.merge(TypefluxDataDirectories.featureEnvironment) { _, value in value }
        self.environment = environment ?? values
    }
    deinit { for child in children.values { child.process.cancel() } }

    func route(_ command: FeatureCommand, timeout: Duration = .seconds(10)) async throws -> Data {
        guard timeout > .zero, timeout <= .seconds(180) else { throw FeatureRPC.Failure.invalidMessage }
        return try await ShortcutLatency.$current.withValue(command.latency) {
            do { return try await routeTraced(command, timeout: timeout) }
            catch { ShortcutLatency.record(.failed); throw error }
        }
    }

    private func routeTraced(_ command: FeatureCommand, timeout: Duration) async throws -> Data {
        ShortcutLatency.record(.hostRouting)
        let draining = command.destination == .background && command.action.hasPrefix("media.") && children[.background] != nil
        let stateUpdate = command.destination == .host && ["status", "voiceState", "focus", "changed"].contains(command.action)
        guard !stopped || draining || stateUpdate else { throw FeatureRPC.Failure.unavailable }
        if command.destination == .host {
            if command.action == "retireFeature" {
                guard let role = FeatureRole(rawValue: String(decoding: command.payload, as: UTF8.self)),
                      [.chat, .screenshot, .background].contains(role), (routesInFlight[role] ?? 0) == 0,
                      let child = children[role] else { return Data() }
                let channel = channelGenerations[role]
                let reply = try await child.peer.request("ui", payload: JSONEncoder().encode(FeatureCommand(destination: role, action: "idleAllowed")), timeout: .seconds(2))
                guard try JSONDecoder().decode(Bool.self, from: reply), (routesInFlight[role] ?? 0) == 0,
                      channelGenerations[role] == channel else { return Data() }
                children[role] = nil
                do {
                    _ = try await child.peer.request("ui", payload: JSONEncoder().encode(FeatureCommand(destination: role, action: "shutdown")), timeout: .seconds(10))
                } catch {
                    if channelGenerations[role] == channel { children[role] = child }
                    return Data()
                }
                await child.peer.stop(); child.process.cancel(); await child.process.value
                return Data()
            }
            if command.action == "resources" {
                var snapshots = [FeatureResourceSnapshot.capture(role: .host)]
                for (role, child) in children {
                    if let data = try? await child.peer.request("ui", payload: JSONEncoder().encode(FeatureCommand(destination: role, action: "resourceSnapshot")), timeout: .seconds(1)),
                       let snapshot = try? JSONDecoder().decode(FeatureResourceSnapshot.self, from: data) { snapshots.append(snapshot) }
                }
                return try JSONEncoder().encode(snapshots.sorted { $0.role.rawValue < $1.role.rawValue })
            }
            if command.action == "indexSnapshot" {
                for (role, child) in children where role == .chat {
                    await child.stateSender.send(.init(destination: role, action: "indexSnapshot", payload: command.payload))
                }
                return try await FeatureProcess.receive(command)
            }
            if command.action == "status" {
                let status = try JSONDecoder().decode(FeatureStatus.self, from: command.payload)
                pendingStatuses[status.role] = status
                moduleStates[status.role] = status.modules
                if !mirrorScheduled {
                    mirrorScheduled = true
                    Task { @MainActor in
                        for status in await self.takeStatuses() {
                            FeatureActivityMirror.shared.receive(status)
                            if let voice = status.voiceStatus {
                                _ = try? await FeatureProcess.receive(.init(destination: .host, action: "voiceStatus", payload: JSONEncoder().encode(voice)))
                            }
                        }
                    }
                }
                return Data()
            }
            if command.action == "moduleHealth" { return try JSONEncoder().encode(moduleStates) }
            if command.action == "recoverModules" {
                let request = try JSONDecoder().decode(FeatureModuleRecovery.self, from: command.payload)
                let targets = moduleStates.filter { _, values in
                    guard let health = values[request.id] else { return false }
                    return health.state != .ready && health.state != .disabled && health.state != .stopped
                }.map(\.key)
                var result: ModuleRecoveryResponse = .ready
                for target in targets {
                    do {
                        let data = try await route(.init(destination: target, action: "recoverModule", payload: command.payload))
                        let response = try JSONDecoder().decode(ModuleRecoveryResponse.self, from: data)
                        if response != .ready { result = response }
                    } catch { result = .unavailable }
                }
                return try JSONEncoder().encode(result)
            }
            if command.action == "changed" {
                guard FeatureProcess.sharedNotifications.contains(Notification.Name(String(decoding: command.payload, as: UTF8.self))) else { throw FeatureRPC.Failure.invalidMessage }
                for (role, child) in children {
                    Task { _ = try? await child.peer.request("ui", payload: JSONEncoder().encode(FeatureCommand(destination: role, action: "changed", payload: command.payload))) }
                }
                Task { _ = try? await FeatureProcess.receive(command) }
                return Data()
            }
            if command.action == "preferences" { await settingsChanged(); return Data() }
            if command.action == "focus" {
                let focus = try JSONDecoder().decode(FeatureFocus.self, from: command.payload)
                if focus.uptime >= focusUptime {
                    focusUptime = focus.uptime
                    if focus.focused { focusedRole = focus.role }
                    else if focusedRole == focus.role { focusedRole = .host }
                }
                return Data()
            }
            if command.action == "claimVoice" {
                guard let role = FeatureRole(rawValue: String(decoding: command.payload, as: UTF8.self)),
                      [FeatureRole.voice, .chat, .launcher, .host].contains(role) else { throw FeatureRPC.Failure.invalidMessage }
                let accepted = voiceOwner == nil || voiceOwner == role
                if accepted { voiceOwner = role }
                return try JSONEncoder().encode(accepted)
            }
            if command.action == "voiceState" {
                let state = try JSONDecoder().decode(FeatureVoiceState.self, from: command.payload)
                if state.recording, voiceOwner == nil { voiceOwner = state.role }
                else if !state.recording, voiceOwner == state.role { voiceOwner = nil }
                let recording = voiceOwner != nil
                Task { _ = try? await self.route(.init(destination: .shortcuts, action: "recording", payload: JSONEncoder().encode(recording))) }
                return Data()
            }
            if command.action == "hotkey", let event = try? JSONDecoder().decode(FeatureHotkeyEvent.self, from: command.payload),
               event.target == nil, event.name != "onPersonaPickerRequested", event.name != "onError" {
                let target = voiceOwner ?? focusedRole
                if target != .host, [.chat, .launcher, .voice].contains(target) {
                    return try await route(.init(destination: target, action: "hotkey", payload: command.payload, latency: command.latency), timeout: timeout)
                }
                return try await FeatureProcess.receive(command)
            }
            if command.action == "hotkey", let event = try? JSONDecoder().decode(FeatureHotkeyEvent.self, from: command.payload), event.name == "onPersonaPickerRequested" {
                return try await route(.init(destination: .voice, action: "hotkey", payload: command.payload, latency: command.latency), timeout: timeout)
            }
            return try await FeatureProcess.receive(command)
        }
        if command.destination == .launcher, command.action == "toggleLauncher", let voiceOwner {
            Task { _ = try? await self.route(.init(destination: voiceOwner, action: "cancelRecording")) }
        }
        if command.destination.processOwner == .host {
            ShortcutLatency.record(.targetWarm)
            return try await FeatureProcess.receive(command)
        }
        ShortcutLatency.record(children[command.destination.processOwner] == nil ? .targetCold : .targetWarm)
        let owner = command.destination.processOwner
        routesInFlight[owner, default: 0] += 1
        defer { routesInFlight[owner, default: 1] -= 1 }
        let child = try await child(for: owner)
        return try await child.peer.request("ui", payload: JSONEncoder().encode(command), timeout: timeout)
    }

    private func takeStatuses() -> [FeatureStatus] {
        let values = Array(pendingStatuses.values)
        pendingStatuses.removeAll(); mirrorScheduled = false
        return values
    }

    func updateAuth(_ snapshot: FeatureAuth) async {
        guard snapshot.generation >= auth.generation else { return }
        if snapshot.generation != auth.generation { executionOwners.removeAll() }
        auth = snapshot
        for (role, child) in children {
            Task {
                _ = try? await child.peer.request("ui", payload: JSONEncoder().encode(FeatureCommand(
                    destination: role, action: "auth", payload: JSONEncoder().encode(snapshot))))
            }
        }
    }

    func settingsChanged() async {
        Task { @MainActor in _ = try? await FeatureProcess.receive(.init(destination: .host, action: "settings")) }
        for (role, child) in children {
            Task { _ = try? await child.peer.request("ui", payload: JSONEncoder().encode(
                FeatureCommand(destination: role, action: "settings"))) }
        }
    }

    private func handleAPI(_ method: String, payload: Data, role: FeatureRole, channel: UUID) async throws -> Data {
        let call = try JSONDecoder().decode(FeatureAskCall.self, from: payload)
        guard channelGenerations[role] == channel, liveChannels.contains(channel) else {
            AskFailureDiagnostics.shared.record(.cacheAuthorization, error: AuthError.unauthorized, reason: .inactiveChannel, method: method)
            return try JSONEncoder().encode(FeatureAskReply(payload: nil, error: .init(AuthError.unauthorized)))
        }
        guard call.generation == auth.generation else {
            AskFailureDiagnostics.shared.record(.cacheAuthorization, error: AuthError.unauthorized, reason: .generationMismatch, method: method)
            return try JSONEncoder().encode(FeatureAskReply(payload: nil, error: .init(AuthError.unauthorized)))
        }
        callsInFlight[channel, default: 0] += 1
        defer {
            callsInFlight[channel, default: 0] -= 1
            if callsInFlight[channel] == 0 { callsInFlight[channel] = nil }
        }
        if method.hasPrefix("cache.") {
            let identity = try JSONDecoder().decode(FeatureCacheIdentity.self, from: call.payload)
            guard identity.owner == "local" || identity.owner == auth.profile?.id else {
                AskFailureDiagnostics.shared.record(.cacheAuthorization, error: AuthError.unauthorized, reason: .ownerMismatch, method: method)
                return try JSONEncoder().encode(FeatureAskReply(payload: nil, error: .init(AuthError.unauthorized)))
            }
            let result = try await FeatureAskCache.handle(method, payload: call.payload, api: cache)
            guard liveChannels.contains(channel), call.generation == auth.generation else { throw FeatureRPC.Failure.cancelled }
            return result
        }
        let metadata = try JSONDecoder().decode(FeatureAPIIdentity.self, from: call.payload)
        let operation = method.split(separator: ".").dropFirst().first.map(String.init) ?? ""
        let key = metadata.conversationId.map { String(call.generation) + ":" + (metadata.token.isEmpty ? "local:" : "account:") + $0 }
        let drives = ["send", "retry", "recover", "regenerate", "resume", "result", "inferenceResult"].contains(operation)
        if drives, let key {
            if let current = executionOwners[key], current.channel != channel,
               liveChannels.contains(current.channel) || (callsInFlight[current.channel] ?? 0) > 0 {
                return try JSONEncoder().encode(FeatureAskReply(payload: nil, error: .init(AskLocalError.message(L("ask.local.conflict")))))
            }
            if executionOwners[key]?.channel != channel { executionOwners[key] = .init(channel: channel, runID: nil) }
        }
        let result = try await FeatureAskAPI.handle(method, payload: call.payload, api: api)
        if let key, let reply = try? JSONDecoder().decode(FeatureAskReply.self, from: result),
           let payload = reply.payload, let value = try? JSONDecoder().decode(FeatureAPIRun.self, from: payload),
           let run = value.run {
            if ["completed", "failed", "cancelled"].contains(run.status),
               executionOwners[key]?.runID == nil || executionOwners[key]?.runID == run.id { executionOwners[key] = nil }
            else if executionOwners[key]?.channel == channel {
                executionOwners[key]?.runID = run.id
            } else if operation == "cancel", executionOwners[key]?.runID == run.id { executionOwners[key] = nil }
        }
        guard channelGenerations[role] == channel, liveChannels.contains(channel), call.generation == auth.generation else {
            throw FeatureRPC.Failure.cancelled
        }
        return result
    }

    func bootstrap(for role: FeatureRole) async throws -> Data {
        // Explicit capture needs auth identity, not the host storage/media startup barrier.
        if role != .screenshot { await preparation?.value }
        return try JSONEncoder().encode(auth)
    }

    @discardableResult

    func shutdown() async -> Bool {
        stopped = true
        for task in starting.values { task.cancel() }
        starting.removeAll()
        let owned = children
        // Keep existing service routes available while presentation owners drain.
        var failed = Set<FeatureRole>()
        await withTaskGroup(of: FeatureRole?.self) { group in
            for (role, child) in owned where role != .background {
                group.addTask {
                    do {
                    _ = try await child.peer.request("ui", payload: JSONEncoder().encode(
                        FeatureCommand(destination: role, action: "shutdown")), timeout: .seconds(30))
                    await child.peer.stop();
                    child.process.cancel(); await child.process.value
                        return nil
                    } catch {
                        Logger(subsystem: "ai.gulu.app.typeflux", category: "Shutdown").error("Cleanup refused by \(role.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                        return role
                    }
                }
            }
            for await role in group {
                if let role {
                    failed.insert(role)
                }
            }
        }
        // Never kill a window owner that could not confirm durable draft/audio cleanup.
        if !failed.isEmpty {
            stopped = false; return false
        }
        if let child = owned[.background] {
            do {
                _ = try await child.peer.request("ui", payload: JSONEncoder().encode(
                    FeatureCommand(destination: .background, action: "shutdown")
                ), timeout: .seconds(60))
                await child.peer.stop(); child.process.cancel();
                    await child.process.value
            } catch {
                Logger(subsystem: "ai.gulu.app.typeflux", category: "Shutdown").error("Background cleanup refused: \(String(describing: error), privacy: .public)")
                stopped = false
                return false
            }
        }
        children.removeAll()
        return true
    }

    private func childExited(role: FeatureRole, channel: UUID) {
        liveChannels.remove(channel)
        if channelGenerations[role] == channel {
            moduleStates[role] = nil
            if role != .background, !stopped, let backend = children[.background] {
                let inactive = FeatureForegroundActivity(busy: false)
                Task {
                    _ = try? await backend.peer.request("ui", payload: JSONEncoder().encode(FeatureCommand(destination: .background,
                        action: "media.ownerExited", payload: JSONEncoder().encode(role))))
                    _ = try? await backend.peer.request("ui", payload: JSONEncoder().encode(FeatureCommand(destination: .background,
                        action: "semantic.busy." + role.rawValue, payload: JSONEncoder().encode(inactive))))
                    if role == .voice {
                        _ = try? await backend.peer.request("ui", payload: JSONEncoder().encode(FeatureCommand(destination: .background,
                            action: "semantic.busy.voiceEditor", payload: JSONEncoder().encode(inactive))))
                    }
                }
            }
            children[role] = nil
            if focusedRole == role { focusedRole = .host }
            if voiceOwner == role {
                voiceOwner = nil
                Task { _ = try? await self.route(.init(destination: .shortcuts, action: "recording", payload: JSONEncoder().encode(false))) }
            }
            Task { @MainActor in
                FeatureActivityMirror.shared.remove(role)
                if role == .voice { _ = try? await FeatureProcess.receive(.init(destination: .host, action: "voiceStatus", payload: JSONEncoder().encode(AppStatus.idle))) }
            }

        }
    }

    private func child(for role: FeatureRole) async throws -> Child {
        guard role != .host, role.processOwner == role else { throw FeatureRPC.Failure.invalidMessage }
        if let child = children[role] { return child }
        if let task = starting[role] { return try await task.value }
        ShortcutLatency.record(.spawnRequested)
        let now = ContinuousClock.now
        launches[role] = (launches[role] ?? []).filter { $0.duration(to: now) < .seconds(60) }
        guard (launches[role]?.count ?? 0) < 3 else { throw FeatureRPC.Failure.busy }
        launches[role, default: []].append(now)
        let channel = UUID()
        channelGenerations[role] = channel
        liveChannels.insert(channel)
        let executable = executableURL.path, childEnvironment = environment
        let task = Task<Child, Error> { [weak self] in
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw FeatureRPC.Failure.unavailable }
            guard pair.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else {
                pair.forEach { close($0) }; throw FeatureRPC.Failure.unavailable
            }
            let inherited = FeatureInheritedDescriptor(pair[1])
            let peer = try FeatureRPC(descriptor: pair[0])
            await peer.start { [weak self] method, payload in
                if method == "bootstrap", let self { return try await self.bootstrap(for: role) }
                if (method.hasPrefix("ask.") || method.hasPrefix("cache.")), [FeatureRole.chat, .launcher, .settings, .notes, .wordBook, .help, .translation].contains(role), let self {
                    return try await self.handleAPI(method, payload: payload, role: role, channel: channel)
                }
                if method == "dispatch", role == .shortcuts, let self {
                    let command = try JSONDecoder().decode(FeatureCommand.self, from: payload)
                    ShortcutLatency.record(.hostReceived, trace: command.latency)
                    Task { _ = try? await self.route(command) }
                    return try JSONEncoder().encode(FeatureRPC.Empty())
                }
                if method == "route", let self {
                    let request = try JSONDecoder().decode(FeatureRoutedCommand.self, from: payload)
                    guard (1...180000).contains(request.timeoutMilliseconds) else { throw FeatureRPC.Failure.invalidMessage }
                    let result = try await self.route(request.command, timeout: .milliseconds(request.timeoutMilliseconds))
                    return try JSONEncoder().encode(result)
                }
                throw FeatureRPC.Failure.invalidMessage
            }
            let latency = ShortcutLatency.current
            let process = Task.detached {
                let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                defer { if directory >= 0 { close(directory) }; inherited.closeOnce() }
                if directory >= 0 {
                    let result = try? await ManagedProcess().run(.init(executable: executable,
                        arguments: ["--feature-process", role.rawValue, "--ipc-fd", "100"],
                        environment: childEnvironment,
                        directoryDescriptor: directory, timeout: 86400,
                        outputLimit: 64 * 1024, onStarted: { inherited.closeOnce(); ShortcutLatency.record(.processStarted, trace: latency) },
                        stderrLimit: 64 * 1024, immediateCleanupOnExit: true, ipcDescriptor: inherited.descriptor, ownedApplicationLifetime: true))
                    if childEnvironment["TYPEFLUX_FEATURE_FIXTURE"] == "1", let result {
                        print("FEATURE_EXIT role=\(role.rawValue) code=\(result.exitCode) stderr=\(result.stderr)")
                    }
                }
                await peer.stop()
                await self?.childExited(role: role, channel: channel)
            }
            let stateSender = await FeatureCommandSender(route: { command in
                try await peer.request("ui", payload: JSONEncoder().encode(command))
            })
            return Child(peer: peer, stateSender: stateSender, process: process)
        }
        starting[role] = task
        do {
            let child = try await task.value
            starting[role] = nil
            if stopped || !liveChannels.contains(channel) { await child.peer.stop(); child.process.cancel(); throw FeatureRPC.Failure.unavailable }
            children[role] = child
            return child
        } catch { starting[role] = nil; liveChannels.remove(channel); throw error }
    }
}

private final class FeatureInheritedDescriptor: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { closeOnce() }
    func closeOnce() { lock.withLock { if !closed { closed = true; close(descriptor) } } }
}

private final class FeatureRuntimeConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (role: FeatureRole, enabled: Bool) = (.host, false)
    var value: (role: FeatureRole, enabled: Bool) { lock.withLock { stored } }
    func install(_ role: FeatureRole) { lock.withLock { stored = (role, true) } }
}

private struct FeatureExecutionOwner {
    let channel: UUID
    var runID: String?
}
private struct FeatureAPIIdentity: Decodable {
    let token: String
    let conversationId: String?
    private enum CodingKeys: String, CodingKey { case token, conversationId, id }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decode(String.self, forKey: .token)
        conversationId = try values.decodeIfPresent(String.self, forKey: .conversationId) ?? values.decodeIfPresent(String.self, forKey: .id)
    }
}
private struct FeatureAPIRun: Decodable {
    struct Run: Decodable { let id: String; let status: String }
    let run: Run?
}

struct FeatureFocus: Codable, Sendable {
    let role: FeatureRole
    let focused: Bool
    let uptime: TimeInterval
}
struct FeatureForegroundActivity: Codable, Sendable {
    let busy: Bool
    let uptime: TimeInterval
    init(busy: Bool, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.busy = busy; self.uptime = uptime
    }
}

struct FeatureVoiceState: Codable, Sendable {
    let role: FeatureRole
    let recording: Bool
}

private struct FeatureCacheIdentity: Decodable { let owner: String }

/// Keeps child command cleanup independent of the feature's AppKit thread.
private final class FeatureParentLifetime: @unchecked Sendable {
    let parent: pid_t
    private var deadline: ContinuousClock.Instant?
    init(parent: pid_t) { self.parent = parent }
    func check() {
        guard getppid() != parent else { return }
        if deadline == nil {
            ManagedProcess.cancelAllForApplicationExit()
            deadline = .now.advanced(by: .seconds(11))
        }
        if ManagedProcess.activeApplicationProcesses == 0 || ContinuousClock.now >= deadline! { _exit(0) }
    }
}

extension FeatureRole {
    var modules: [ModuleID] {
        switch self {
        case .host: [.conversations, .notebook, .wordBook, .nativeSystem, .mediaExtraction, .mediaPreviews, .clipboardThumbnails, .textRecognition, .clipboardOCR, .clipboardMetadata, .mediaPlayback]
        case .background: [.fileIndex, .semanticValidation, .semanticIndexReading, .semanticPriorityReading, .semanticQueryInference, .semanticIndexInference, .semanticMediaInference]
        case .shortcuts, .settings: []
        case .voice: [.whisperInference]
        case .ring, .monitor: [.nativeSystem]
        case .screenshot: [
            .frameRegistration, .textRecognition, .recordingTimeline, .recordingExport,
            .mediaPlayback, .mediaPreviews, .mediaExtraction
        ]
        case .clipboard: [.clipboardThumbnails, .clipboardOCR, .clipboardMetadata, .mediaPlayback, .mediaPreviews, .mediaExtraction]
        case .chat: [.notebook, .wordBook, .nativeSystem, .mediaExtraction, .mediaPreviews, .textRecognition, .mediaPlayback]
        case .launcher: ModuleID.allCases.filter { $0 != .conversations }
        case .notes, .wordBook, .help, .translation: [.notebook, .wordBook, .textRecognition, .mediaPreviews, .mediaExtraction]
        }
    }
}
