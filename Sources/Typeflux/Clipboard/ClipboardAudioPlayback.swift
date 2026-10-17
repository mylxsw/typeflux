import AppKit
import Combine
import Foundation
import ObjectiveC
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
    @Published private(set) var image: NSImage?
    @Published private(set) var volume: Double = 1
    private let video: Bool
    private let budget: AskToolPixelBudget
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
    private var commandRange: MediaPlaybackRange?
    init(video: Bool = false, budget: AskToolPixelBudget = .shared, open: Open? = nil) {
        self.video = video; self.budget = budget
        self.open = open ?? { try await ClipboardPlaybackProcess.open($0, video: video) }
    }
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
        operation = Task { [weak self, open, video, budget] in
            defer { self?.operationFinished() }
            var owned: (any ClipboardPlaybackClient)?
            defer { owned?.stop() }
            do {
                // Reserve incoming transport and construction pixels before dispatch, and retain through
                // uncooperative work even after the view has cleared its own reference.
                let reservation = video ? try budget.acquire(bytes: MediaPlaybackFrame.maximumBytes * 2) : nil
                defer { withExtendedLifetime(reservation) {} }
                let client = try await open(url); owned = client
                guard !Task.isCancelled, self?.permits(current) == true else { return }
                self?.client = client
                if let reservation { try client.retainPixels(reservation) }
                var next: (MediaPlaybackMessage.Kind, Double?) = (.load, nil)
                var range: MediaPlaybackRange?
                while !Task.isCancelled {
                    guard self?.permits(current) == true else { self?.stop(); return }
                    let state = try await withTaskCancellationHandler {
                        try await client.request(next.0, fraction: next.1, range: range)
                    } onCancel: { client.stop() }
                    try Task.checkCancellation()
                    try state.validate()
                    guard self?.permits(current) == true else { self?.stop(); return }
                    guard state.video == video, !video || state.frame != nil else { throw MediaFailure.invalidProtocol }
                    let image = try Self.image(state, budget: budget)
                    self?.image = image
                    self?.apply(state)
                    if next.0 != .status { self?.isBusy = false }
                    try await Task.sleep(for: .milliseconds(video && state.phase == .playing ? 33 : 250))
                    guard self?.permits(current) == true else { self?.stop(); return }
                    range = self?.commandRange; self?.commandRange = nil
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
        volume = state.volume
        duration = state.duration; elapsed = state.elapsed; progress = elapsed / duration
    }
    func toggle() { submit(isPlaying ? .pause : .play, fraction: nil) }
    func play(range: MediaPlaybackRange) {
        guard (try? range.validate()) != nil, range.end <= duration, isLoaded, !isBusy, command == nil,
              originalAccess?.allows() == true else { return }
        commandRange = range; submit(.playRange, fraction: nil)
    }
    func seekPaused(to fraction: Double) {
        guard fraction.isFinite, isLoaded, originalAccess?.allows() == true,
              command == nil || command?.0 == .seekPaused else { return }
        // Scrubbing coalesces only unsent read-only seeks, never a play/write operation.
        command = (.seekPaused, min(1, max(0, fraction))); commandRange = nil; isBusy = true
    }
    func prepare(_ url: URL, access: AskImagePresentationAccess) async throws -> Double {
        load(url, access: access)
        do {
            while isBusy && !isLoaded { try await Task.sleep(for: .milliseconds(10)) }
            try Task.checkCancellation()
            guard access.allows(), isLoaded else { throw MediaFailure.unavailable }
            return duration
        } catch { stop(); throw error }
    }
    var interactionID: UUID { generation }
    func seek(to fraction: Double, interactionID: UUID) {
        guard interactionID == generation else { return }
        seek(to: fraction)
    }
    func setVolume(_ value: Double, interactionID: UUID) {
        guard interactionID == generation else { return }
        setVolume(value)
    }
    func seek(to fraction: Double) {
        guard fraction.isFinite else { return }
        submit(.seek, fraction: min(1, max(0, fraction)))
    }
    func setVolume(_ value: Double) {
        guard video, value.isFinite else { return }
        submit(.volume, fraction: min(1, max(0, value)))
    }
    private static func image(_ state: MediaPlaybackState, budget: AskToolPixelBudget) throws -> NSImage? {
        guard let frame = state.frame else {
            guard state.pixels == nil else { throw MediaFailure.invalidProtocol }; return nil
        }
        guard let pixels = state.pixels, pixels.count == frame.bytes else { throw MediaFailure.invalidProtocol }
        let reservation = try budget.acquire(bytes: frame.bytes)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let cg = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: frame.stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw MediaFailure.invalidProtocol }
        let image = NSImage(size: NSSize(width: frame.width, height: frame.height))
        ClipboardVideoImageReservation.retain(reservation, on: image)
        image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        return image
    }
    private func submit(_ kind: MediaPlaybackMessage.Kind, fraction: Double?) {
        guard isLoaded, !isBusy, command == nil, originalAccess?.allows() == true else { return }
        command = (kind, fraction); isBusy = true
    }
    private func clear() {
        client?.stop(); client = nil; command = nil; commandRange = nil
        isLoaded = false; isPlaying = false; isBusy = false; failed = false
        progress = 0; elapsed = 0; duration = 0; volume = 1; image = nil
    }
    func cancel() { stop() }
    func stop() {
        generation = UUID(); pendingLoad = nil; operation?.cancel(); clear(); identity = nil; originalAccess = nil
        if let registration { scope?.remove(registration) }
        registration = nil; scope = nil
    }
}

/// A separate reservation follows each actual displayed image, even if SwiftUI retains
/// old frames. Exhaustion stops presentation rather than growing a hidden frame history.
@MainActor private enum ClipboardVideoImageReservation {
    private static var key: UInt8 = 0

    static func retain(_ reservation: AskToolPixelBudget.Lease, on image: NSImage) {
        withUnsafePointer(to: &key) { pointer in
            objc_setAssociatedObject(image, pointer, reservation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
