import Darwin
import Foundation

/// A private rendezvous for replacing a broken inherited channel without
/// terminating the presentation process. The random directory is owner-only;
/// the capability is never exposed through diagnostics or UI.
final class FeatureReconnectListener: @unchecked Sendable {
    private let descriptor: Int32
    private let directory: String
    let path: String
    let secret: String
    private let lock = NSLock()
    private var stopped = false
    private var expectedPeerPID: pid_t?

    init() throws {
        directory = "/tmp/typeflux-ipc-" + UUID().uuidString
        path = directory + "/socket"
        secret = UUID().uuidString
        guard mkdir(directory, 0o700) == 0 else { throw FeatureRPC.Failure.unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { rmdir(directory); throw FeatureRPC.Failure.unavailable }
        do {
            try Self.configure(fd)
            var address = try Self.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, listen(fd, 4) == 0 else { throw FeatureRPC.Failure.unavailable }
            descriptor = fd
        } catch {
            close(fd); unlink(path); rmdir(directory); throw error
        }
    }

    deinit { stop(); close(descriptor) }
    func setExpectedPeerPID(_ pid: pid_t) { lock.withLock { expectedPeerPID = pid } }
    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            shutdown(descriptor, SHUT_RDWR)
            unlink(path); rmdir(directory)
        }
    }

    func acceptConnection() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try self.acceptBlocking() })
                }
            }
        } onCancel: {
            stop()
        }
    }

    private func acceptBlocking() throws -> Int32 {
        while !lock.withLock({ stopped }) {
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 500)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw FeatureRPC.Failure.unavailable }
            let fd = accept(descriptor, nil, nil)
            guard fd >= 0 else { continue }
            do {
                try Self.configure(fd)
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw FeatureRPC.Failure.unavailable }
                guard let expectedPID = lock.withLock({ expectedPeerPID }), try Self.peerPID(fd) == expectedPID else {
                    throw FeatureRPC.Failure.unavailable
                }
                let expected = Array(secret.utf8)
                var received = [UInt8](repeating: 0, count: expected.count)
                try Self.transfer(fd, bytes: &received, writing: false)
                guard received == expected else { throw FeatureRPC.Failure.unavailable }
                return fd
            } catch { close(fd) }
        }
        throw FeatureRPC.Failure.unavailable
    }

    static func connect(path: String, secret: String, expectedPeerPID: pid_t = getppid()) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                    guard fd >= 0 else { throw FeatureRPC.Failure.unavailable }
                    do {
                        try configure(fd)
                        var address = try address(path)
                        let result = withUnsafePointer(to: &address) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                            }
                        }
                        guard result == 0 else { throw FeatureRPC.Failure.unavailable }
                        var uid: uid_t = 0, gid: gid_t = 0
                        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                            throw FeatureRPC.Failure.unavailable
                        }
                        guard try peerPID(fd) == expectedPeerPID else { throw FeatureRPC.Failure.unavailable }
                        var bytes = Array(secret.utf8)
                        guard bytes.count == 36 else { throw FeatureRPC.Failure.invalidMessage }
                        try transfer(fd, bytes: &bytes, writing: true)
                        return fd
                    } catch { close(fd); throw error }
                })
            }
        }
    }

    private static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw FeatureRPC.Failure.unavailable
        }
    }

    private static func peerPID(_ fd: Int32) throws -> pid_t {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              size == socklen_t(MemoryLayout<pid_t>.size) else { throw FeatureRPC.Failure.unavailable }
        return pid
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw FeatureRPC.Failure.invalidMessage }
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        return value
    }

    private static func transfer(_ fd: Int32, bytes: inout [UInt8], writing: Bool) throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ContinuousClock.now < end else { throw FeatureRPC.Failure.timedOut }
                var item = pollfd(fd: fd, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
                guard poll(&item, 1, 200) > 0 else { continue }
                let pointer = buffer.baseAddress!.advanced(by: offset)
                let count = writing ? Darwin.write(fd, pointer, buffer.count - offset)
                    : Darwin.read(fd, pointer, buffer.count - offset)
                guard count > 0 else { throw FeatureRPC.Failure.unavailable }
                offset += count
            }
        }
    }
}
