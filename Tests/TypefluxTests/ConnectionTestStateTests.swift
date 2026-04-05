@testable import Typeflux
import XCTest

final class ConnectionTestStateTests: XCTestCase {
    // MARK: - ConnectionTestState

    func testConnectionTestStateIdle() {
        let state = ConnectionTestState.idle
        XCTAssertEqual(state, .idle)
    }

    func testConnectionTestStateTesting() {
        let state = ConnectionTestState.testing
        XCTAssertEqual(state, .testing)
    }

    func testConnectionTestStateSuccess() {
        let state = ConnectionTestState.success(firstTokenMs: 100, totalMs: 500, preview: "Hello")
        XCTAssertEqual(state, .success(firstTokenMs: 100, totalMs: 500, preview: "Hello"))
    }

    func testConnectionTestStateSuccessNotEqualWithDifferentValues() {
        let a = ConnectionTestState.success(firstTokenMs: 100, totalMs: 500, preview: "Hello")
        let b = ConnectionTestState.success(firstTokenMs: 200, totalMs: 600, preview: "World")
        XCTAssertNotEqual(a, b)
    }

    func testConnectionTestStateFailure() {
        let state = ConnectionTestState.failure(message: "timeout")
        XCTAssertEqual(state, .failure(message: "timeout"))
    }

    func testConnectionTestStateFailureNotEqualWithDifferentMessages() {
        let a = ConnectionTestState.failure(message: "timeout")
        let b = ConnectionTestState.failure(message: "unauthorized")
        XCTAssertNotEqual(a, b)
    }

    func testConnectionTestStateIdleNotEqualToTesting() {
        XCTAssertNotEqual(ConnectionTestState.idle, ConnectionTestState.testing)
    }

    // MARK: - MCPTransportType

    func testMCPTransportTypeRawValues() {
        XCTAssertEqual(MCPTransportType.stdio.rawValue, "stdio")
        XCTAssertEqual(MCPTransportType.http.rawValue, "http")
    }

    func testMCPTransportTypeAllCases() {
        let allCases = MCPTransportType.allCases
        XCTAssertEqual(allCases.count, 2)
        XCTAssertTrue(allCases.contains(.stdio))
        XCTAssertTrue(allCases.contains(.http))
    }

    func testMCPTransportTypeInitFromRawValue() {
        XCTAssertEqual(MCPTransportType(rawValue: "stdio"), .stdio)
        XCTAssertEqual(MCPTransportType(rawValue: "http"), .http)
        XCTAssertNil(MCPTransportType(rawValue: "grpc"))
    }

    // MARK: - MCPConnectionTestState

    func testMCPConnectionTestStateIdle() {
        let state = MCPConnectionTestState.idle
        XCTAssertEqual(state, .idle)
    }

    func testMCPConnectionTestStateTesting() {
        let state = MCPConnectionTestState.testing
        XCTAssertEqual(state, .testing)
    }

    func testMCPConnectionTestStateSuccess() {
        let tools = [
            MCPConnectionTestState.MCPDiscoveredTool(id: "1", name: "tool-a", description: "desc a"),
            MCPConnectionTestState.MCPDiscoveredTool(id: "2", name: "tool-b", description: "desc b"),
        ]
        let state = MCPConnectionTestState.success(tools: tools)
        XCTAssertEqual(state, .success(tools: tools))
    }

    func testMCPConnectionTestStateFailure() {
        let state = MCPConnectionTestState.failure(message: "connection refused")
        XCTAssertEqual(state, .failure(message: "connection refused"))
    }

    func testMCPConnectionTestStateIdleNotEqualToTesting() {
        XCTAssertNotEqual(MCPConnectionTestState.idle, MCPConnectionTestState.testing)
    }

    // MARK: - MCPDiscoveredTool

    func testMCPDiscoveredToolProperties() {
        let tool = MCPConnectionTestState.MCPDiscoveredTool(id: "tool-1", name: "search", description: "Search the web")
        XCTAssertEqual(tool.id, "tool-1")
        XCTAssertEqual(tool.name, "search")
        XCTAssertEqual(tool.description, "Search the web")
    }

    func testMCPDiscoveredToolEquality() {
        let a = MCPConnectionTestState.MCPDiscoveredTool(id: "1", name: "search", description: "desc")
        let b = MCPConnectionTestState.MCPDiscoveredTool(id: "1", name: "search", description: "desc")
        XCTAssertEqual(a, b)
    }

    func testMCPDiscoveredToolInequalityByName() {
        let a = MCPConnectionTestState.MCPDiscoveredTool(id: "1", name: "search", description: "desc")
        let b = MCPConnectionTestState.MCPDiscoveredTool(id: "1", name: "fetch", description: "desc")
        XCTAssertNotEqual(a, b)
    }
}
