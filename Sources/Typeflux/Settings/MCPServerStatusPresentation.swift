import SwiftUI

/// How a saved MCP server's row describes its state: off, untested, connecting, connected or failing.
struct MCPServerStatusPresentation: Equatable {
    enum State: Equatable { case disabled, untested, testing, connected, failed }

    let state: State
    let label: String

    init(enabled: Bool, result: MCPConnectionTestState?) {
        switch (enabled, result) {
        case (false, _):
            (state, label) = (.disabled, L("agent.mcp.status.disabled"))
        case (true, .testing?):
            (state, label) = (.testing, L("agent.mcp.testing"))
        case let (true, .success(tools)?):
            (state, label) = (.connected, L("agent.mcp.status.connected", tools.count))
        case (true, .failure?):
            (state, label) = (.failed, L("agent.mcp.status.failed"))
        case (true, .idle?), (true, nil):
            (state, label) = (.untested, L("agent.mcp.status.untested"))
        }
    }

    var isTesting: Bool {
        state == .testing
    }

    var tone: TypefluxTone {
        switch state {
        case .connected: .success
        case .failed: .danger
        case .testing: .warning
        case .disabled, .untested: .inactive
        }
    }
}
