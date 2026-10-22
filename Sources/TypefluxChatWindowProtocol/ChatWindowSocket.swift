import Darwin
import Foundation

/// One reader and one writer. Closing wakes both without reusing their descriptor.
/// The descriptor itself stays owned until all in-flight users release this object.
public final class ChatWindowSocket: @unchecked Sendable {
    public static let maximumFrameBytes = 512 * 1024
    public let descriptor: Int32
    private let state = NSLock()
    private var stopped = false

    public init(owning descriptor: Int32) throws {
        self.descriptor = descriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            close(descriptor)
            throw ChatWindowFailure.unavailable
        }
    }

    deinit { close(descriptor) }

    public func stop() {
        state.lock(); defer { state.unlock() }
        guard !stopped else { return }
        stopped = true
        shutdown(descriptor, SHUT_RDWR)
    }

    public var isStopped: Bool { state.lock(); defer { state.unlock() }; return stopped }

    public func send(_ message: ChatWindowEnvelope, deadline: ContinuousClock.Instant) throws {
        try message.validate()
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= Self.maximumFrameBytes else { throw ChatWindowFailure.invalidProtocol }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try transfer(&frame, writing: true, deadline: deadline)
    }

    public func receive(deadline: ContinuousClock.Instant) throws -> ChatWindowEnvelope {
        var header = Data(count: 4)
        try transfer(&header, writing: false, deadline: deadline)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= Self.maximumFrameBytes else { throw ChatWindowFailure.invalidProtocol }
        var payload = Data(count: Int(size))
        try transfer(&payload, writing: false, deadline: deadline)
        guard let message = try? JSONDecoder().decode(ChatWindowEnvelope.self, from: payload) else {
            throw ChatWindowFailure.invalidProtocol
        }
        try message.validate()
        return message
    }

    private func transfer(_ data: inout Data, writing: Bool, deadline: ContinuousClock.Instant) throws {
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard !isStopped else { throw ChatWindowFailure.cancelled }
                guard ContinuousClock.now < deadline else { throw ChatWindowFailure.timedOut }
                let pointer = buffer.baseAddress!.advanced(by: offset)
                let count = writing ? Darwin.write(descriptor, pointer, buffer.count - offset)
                    : Darwin.read(descriptor, pointer, buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count == 0 { throw ChatWindowFailure.unavailable }
                guard errno == EAGAIN || errno == EINTR else { throw ChatWindowFailure.unavailable }
                var item = pollfd(fd: descriptor, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
                _ = poll(&item, 1, 10)
            }
        }
    }
}
