import Darwin
import Foundation

/// Keeps the actual listener open, rather than promising a currently unused
/// number. Only a scoped runtime handle exposes the address after readiness.
final class AskProjectPortLease {
    private(set) var descriptor: Int32
    let port: UInt16
    let token = UUID().uuidString.lowercased()

    init(requested: UInt16) throws {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw AskProjectRuntimeError.portUnavailable }
        descriptor = fileDescriptor
        var address = Self.address(port: requested)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(
                fileDescriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            ) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fileDescriptor, $0, &size) }
        }
        guard bound == 0, named == 0, listen(fileDescriptor, 16) == 0,
              fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            close(fileDescriptor); descriptor = -1; throw AskProjectRuntimeError.portUnavailable
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { release() }

    func release() {
        if descriptor >= 0 {
            close(descriptor); descriptor = -1
        }
    }

    static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    /// A listening socket alone is not readiness. Require a live HTTP response
    /// containing the private per-lease nonce; never follow redirects or use DNS.
    func probe() -> Bool {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }
        var one: Int32 = 1
        guard fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == 0, fcntl(fileDescriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { return false }
        var address = Self.address(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(
                fileDescriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            ) }
        }
        guard connected == 0 || errno == EINPROGRESS else { return false }
        var item = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&item, 1, 20) > 0 else { return false }
        let request = Data("GET /__typeflux_ready/\(token) HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        let sent = request.withUnsafeBytes { send(fileDescriptor, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return false }
        return receiveReadyResponse(fileDescriptor)
    }

    private func receiveReadyResponse(_ fileDescriptor: Int32) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        var item = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline, data.count < bytes.count {
            guard poll(&item, 1, 5) > 0 else { continue }
            let count = recv(fileDescriptor, &bytes, bytes.count - data.count, 0)
            if count < 0, errno == EAGAIN || errno == EINTR {
                continue
            }
            guard count > 0 else { return false }
            data.append(contentsOf: bytes.prefix(count))
            guard let response = String(data: data, encoding: .utf8) else { continue }
            if response.hasPrefix("HTTP/1.0 200 ") || response.hasPrefix("HTTP/1.1 200 "),
               response.components(separatedBy: "\r\n\r\n").last == token {
                return true
            }
        }
        return false
    }
}
