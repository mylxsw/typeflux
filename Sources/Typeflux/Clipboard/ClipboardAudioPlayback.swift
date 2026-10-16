import Combine
import Foundation
import TypefluxMediaProtocol

/// One view owns one silent load and one explicit command slot. No command is retried.
@MainActor final class ClipboardAudioPlayback: ObservableObject, AskImageScopeObserver {
    typealias Open = @Sendable (URL) async throws -> any ClipboardPlaybackClient
    struct Identity: Hashable { let url: URL; let epoch: UUID? }
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var failed = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private let open: Open
    private var operation: Task<Void, Never>?
    private var client: (any ClipboardPlaybackClient)?
    private var identity: Identity?
    private var generation = UUID()
    private var originalAccess: AskImagePresentationAccess?
    private weak var scope: AskImagePresentationScope?
    private var registration: UUID?
    private var pendingLoad: (URL, AskImagePresentationAccess)?
    private var command: (MediaPlaybackMessage.Kind, Double?)?
    init(open: @escaping Open = { try await ClipboardPlaybackProcess.open($0) }) { self.open = open }
    deinit { operation?.cancel(); client?.stop() }

    func load(_ url: URL, access: AskImagePresentationAccess) {
        guard access.allows() else { if identity?.epoch == access.epoch { stop() }; return }
        let next = Identity(url: url, epoch: access.epoch)
        guard identity != next else { return }
        stop()
        // Even a cancelled, uncooperative factory owns its slot until it actually returns.
        guard operation == nil else { pendingLoad = (url, access); isBusy = true; return }
        identity = next; originalAccess = access; isBusy = true
        let current = generation
        do {
            guard let scope = access.scope, let epoch = access.epoch else { return }
            self.scope = scope; registration = try scope.register(self, epoch: epoch)
        } catch { isBusy = false; failed = true; return }
        operation = Task { [weak self, open] in
            defer { self?.operationFinished() }
            var owned: (any ClipboardPlaybackClient)?
            defer { owned?.stop() }
            do {
                let client = try await open(url); owned = client
                guard !Task.isCancelled, self?.permits(current) == true else { return }
                self?.client = client
                var next: (MediaPlaybackMessage.Kind, Double?) = (.load, nil)
                while !Task.isCancelled {
                    guard self?.permits(current) == true else { self?.stop(); return }
                    let state = try await withTaskCancellationHandler {
                        try await client.request(next.0, fraction: next.1)
                    } onCancel: { client.stop() }
                    try Task.checkCancellation()
                    try state.validate()
                    guard self?.permits(current) == true else { self?.stop(); return }
                    self?.apply(state)
                    if next.0 != .status { self?.isBusy = false }
                    try await Task.sleep(for: .milliseconds(250))
                    guard self?.permits(current) == true else { self?.stop(); return }
                    next = self?.takeCommand() ?? (.status, nil)
                }
            } catch {
                guard self?.generation == current else { return }
                self?.clear()
                self?.failed = !Task.isCancelled && access.allows()
            }
        }
    }
    private func operationFinished() {
        operation = nil
        let pending = pendingLoad; pendingLoad = nil
        if let pending, pending.1.allows() { load(pending.0, access: pending.1) }
        else if pending != nil { clear() }
    }
    private func permits(_ current: UUID) -> Bool { current == generation && originalAccess?.allows() == true }
    private func takeCommand() -> (MediaPlaybackMessage.Kind, Double?)? { defer { command = nil }; return command }
    private func apply(_ state: MediaPlaybackState) {
        isLoaded = true; isPlaying = state.phase == .playing
        duration = state.duration; elapsed = state.elapsed; progress = elapsed / duration
    }
    func toggle() { submit(isPlaying ? .pause : .play, fraction: nil) }
    func seek(to fraction: Double) {
        guard fraction.isFinite else { return }
        submit(.seek, fraction: min(1, max(0, fraction)))
    }
    private func submit(_ kind: MediaPlaybackMessage.Kind, fraction: Double?) {
        guard isLoaded, !isBusy, command == nil, originalAccess?.allows() == true else { return }
        command = (kind, fraction); isBusy = true
    }
    private func clear() {
        client?.stop(); client = nil; command = nil
        isLoaded = false; isPlaying = false; isBusy = false; failed = false
        progress = 0; elapsed = 0; duration = 0
    }
    func cancel() { stop() }
    func stop() {
        generation = UUID(); pendingLoad = nil; operation?.cancel(); clear(); identity = nil; originalAccess = nil
        if let registration { scope?.remove(registration) }
        registration = nil; scope = nil
    }
}
