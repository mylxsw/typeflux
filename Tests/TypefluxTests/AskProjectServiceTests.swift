import Darwin
@testable import Typeflux
import XCTest

@MainActor
final class AskProjectServiceTests: XCTestCase {
    typealias Fixture = AskProjectRuntimeTests.Fixture

    private let service = #"""
    import os,socket
    listener=socket.socket(fileno=int(os.environ['TYPEFLUX_LISTEN_FD']))
    token=os.environ['TYPEFLUX_READY_TOKEN']
    while True:
        client,peer=listener.accept()
        try:
            request=client.recv(4096)
            body=token.encode() if b'/__typeflux_ready/' in request else b'project result'
            client.sendall(b'HTTP/1.0 200 OK\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
        except OSError: pass
        finally: client.close()
    """#

    func testServiceReadinessAndLeasePortOwnership() async throws {
        let fixture = try Fixture(service); defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py"); request.servicePort = 0
        let lease = try fixture.launch(request)
        let status = try await fixture.wait(lease, ready: true)
        XCTAssertEqual(status.state, .ready, (try? fixture.text(lease)) ?? "Output unavailable")
        let address = try XCTUnwrap(fixture.runtime.serviceAddress(lease, scope: fixture.scope))
        XCTAssertEqual(address.host, "127.0.0.1")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: address)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "project result")
        XCTAssertThrowsError(try AskProjectPortLease(requested: XCTUnwrap(lease.port)))
        try fixture.runtime.stop(lease, scope: fixture.scope)
        XCTAssertNil(try fixture.runtime.serviceAddress(lease, scope: fixture.scope))
        XCTAssertEqual(kill(status.pid, 0), -1)
        // A stopped listener cannot accept another connection, even if TIME_WAIT
        // temporarily prevents rebinding the port.
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var target = try AskProjectPortLease.address(port: XCTUnwrap(lease.port))
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, -1)
    }

    func testPortConflictFailsWithoutPublishingLeaseOrStartingProcess() throws {
        let occupied = try AskProjectPortLease(requested: 0)
        let fixture = try Fixture(service); defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py"); request.servicePort = occupied.port
        XCTAssertThrowsError(try fixture.launch(request)) { error in
            XCTAssertEqual(error as? AskProjectRuntimeError, .portUnavailable)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.base.appendingPathComponent("runtime").path),
            []
        )
    }

    func testReadinessTimeoutReapsAndReleasesReservedListener() async throws {
        let fixture = try Fixture("import time; time.sleep(30)"); defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py")
        request.servicePort = 0; request.readinessTimeout = 0.15
        let lease = try fixture.launch(request)
        XCTAssertNil(try fixture.runtime.serviceAddress(lease, scope: fixture.scope))
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.state, .readinessTimedOut)
        XCTAssertEqual(kill(status.pid, 0), -1)
        XCTAssertNil(try fixture.runtime.serviceAddress(lease, scope: fixture.scope))
    }

    func testUnrelatedHTTPResponseDoesNotPassReadiness() async throws {
        let fixture = try Fixture(service.replacingOccurrences(
            of: "token=os.environ['TYPEFLUX_READY_TOKEN']",
            with: "token='wrong'"
        ))
        defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py")
        request.servicePort = 0; request.readinessTimeout = 0.3
        let lease = try fixture.launch(request)
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.state, .readinessTimedOut, (try? fixture.text(lease)) ?? "Output unavailable")
    }

    func testReadinessHandlesSplitHTTPHeadersAndBody() async throws {
        let split = service.replacingOccurrences(of: "client.sendall(", with: "payload=(")
            .replacingOccurrences(of: "    except OSError:", with: """
                    client.sendall(payload[:16])
                    __import__('time').sleep(0.005)
                    client.sendall(payload[16:])
                except OSError:
            """)
        let fixture = try Fixture(split); defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py"); request.servicePort = 0
        let lease = try fixture.launch(request)
        let status = try await fixture.wait(lease, ready: true)
        XCTAssertEqual(status.state, .ready, (try? fixture.text(lease)) ?? "Output unavailable")
    }

    func testServiceCannotConnectOutOrBindWildcardOrAnotherPort() async throws {
        let outside = try AskProjectPortLease(requested: 0)
        let checks = """
        import socket
        for host in ['0.0.0.0', '127.0.0.1']:
            s=socket.socket()
            try: s.bind((host,0)); print('UNEXPECTED')
            except PermissionError: print('denied')
        s=socket.socket()
        try: s.connect(('127.0.0.1',\(outside.port))); print('UNEXPECTED')
        except PermissionError: print('denied')
        """
        let fixture = try Fixture(checks + "\n" + service); defer { fixture.close() }
        var request = AskProjectLaunchRequest(script: "main.py"); request.servicePort = 0
        let lease = try fixture.launch(request)
        let status = try await fixture.wait(lease, ready: true)
        XCTAssertEqual(status.state, .ready, (try? fixture.text(lease)) ?? "Output unavailable")
        XCTAssertEqual(try fixture.text(lease), "denied\ndenied\ndenied\n")
    }
}
