@testable import Typeflux
import XCTest

final class AgentCapabilityStatusTests: XCTestCase {
    private let validAccount = "0123456789abcdef0123456789abcdef"

    private func status(_ capability: AgentCapability, _ inputs: AgentCapabilityInputs) -> AgentCapabilityStatus {
        AgentCapabilityStatus.status(of: capability, inputs: inputs)
    }

    func testWebSearchStates() {
        var inputs = AgentCapabilityInputs()
        XCTAssertEqual(status(.webSearch, inputs).level, .off)
        XCTAssertEqual(status(.webSearch, inputs).label, L("agent.status.off"))

        inputs.newConversationsStayLocal = true
        XCTAssertEqual(status(.webSearch, inputs).level, .attention, "Private conversations have no other way to search")
        XCTAssertEqual(status(.webSearch, inputs).label, L("agent.status.search.localOffline"))

        inputs.searchProvider = .tavily
        inputs.missingSearchFields = [.apiKey]
        XCTAssertEqual(status(.webSearch, inputs).level, .attention)
        XCTAssertEqual(status(.webSearch, inputs).label, L("agent.status.search.incomplete"))

        inputs.missingSearchFields = []
        XCTAssertEqual(status(.webSearch, inputs), AgentCapabilityStatus(capability: .webSearch, level: .ready, label: "Tavily"))
    }

    func testOtherCapabilityStates() {
        var inputs = AgentCapabilityInputs(codeExecutionEnabled: false)
        XCTAssertEqual(status(.files, inputs).level, .off)
        XCTAssertEqual(status(.codeExecution, inputs).label, L("agent.status.code.off"))
        XCTAssertEqual(status(.automation, inputs).level, .attention)
        XCTAssertEqual(status(.skills, inputs).level, .off)
        XCTAssertEqual(status(.mcpServers, inputs).label, L("agent.status.mcp.none"))

        inputs = AgentCapabilityInputs(folderCount: 2, codeExecutionEnabled: true, accessibilityGranted: true,
                                       screenRecordingGranted: false, skillCount: 4, enabledSkillCount: 3,
                                       mcpServerCount: 2, enabledMCPServerCount: 0)
        XCTAssertEqual(status(.files, inputs).label, L("agent.status.files.count", 2))
        XCTAssertEqual(status(.codeExecution, inputs).level, .ready)
        XCTAssertEqual(status(.automation, inputs).level, .attention, "Both permissions are needed")
        XCTAssertEqual(status(.skills, inputs).label, L("agent.status.skills.count", 3, 4))
        XCTAssertEqual(status(.mcpServers, inputs).level, .off, "Servers exist but all are off")

        inputs.screenRecordingGranted = true
        inputs.enabledMCPServerCount = 1
        XCTAssertEqual(status(.automation, inputs).level, .ready)
        XCTAssertEqual(status(.mcpServers, inputs).label, L("agent.status.mcp.count", 1))
        XCTAssertEqual(AgentCapabilityStatus.statuses(for: inputs).map(\.capability), AgentCapability.allCases)
    }

    func testCapabilityPresentationAndDestinations() {
        for capability in AgentCapability.allCases {
            XCTAssertEqual(capability.id, capability.rawValue)
            XCTAssertFalse(capability.title.isEmpty)
            XCTAssertFalse(capability.summary.isEmpty)
            XCTAssertFalse(capability.symbol.isEmpty)
        }
        XCTAssertEqual(AgentCapability.webSearch.pane, .webSearch)
        XCTAssertEqual(AgentCapability.files.pane, .files)
        XCTAssertEqual(AgentCapability.codeExecution.pane, .codeExecution)
        XCTAssertEqual(AgentCapability.automation.pane, .automation)
        XCTAssertEqual(AgentCapability.skills.pane, .skills)
        XCTAssertEqual(AgentCapability.mcpServers.pane, .mcpServers)
        XCTAssertEqual(AgentCapabilityStatus.searchProviderName(.brave), "Brave Search")
        XCTAssertEqual(AgentCapabilityStatus.searchProviderName(.cloudflare), "Cloudflare Web Search")
    }

    func testMCPStatusComesFromTheServerList() {
        XCTAssertEqual(AgentCapabilityStatus.mcpStatus(for: []).level, .off)
        XCTAssertEqual(AgentCapabilityStatus.mcpStatus(for: []).label, L("agent.status.mcp.none"))
        let on = MCPServerConfig(name: "a", transport: .stdio(.init(command: "npx")))
        var off = MCPServerConfig(name: "b", transport: .stdio(.init(command: "npx")))
        off.enabled = false
        let mixed = AgentCapabilityStatus.mcpStatus(for: [on, off])
        XCTAssertEqual(mixed.capability, .mcpServers)
        XCTAssertEqual(mixed.level, .ready)
        XCTAssertEqual(mixed.label, L("agent.status.mcp.count", 1))
        XCTAssertEqual(AgentCapabilityStatus.mcpStatus(for: [off]).level, .off)
    }

    func testMissingSearchFields() {
        XCTAssertEqual(AgentSearchField.missing(in: .init()), [])
        XCTAssertEqual(AgentSearchField.missing(in: .init(provider: .brave, apiKey: "  ")), [.apiKey])
        XCTAssertEqual(AgentSearchField.missing(in: .init(provider: .brave, apiKey: "a\nb")), [.apiKey])
        XCTAssertEqual(AgentSearchField.missing(in: .init(provider: .brave, apiKey: "key")), [])

        var cloudflare = AskSearchConfiguration(provider: .cloudflare)
        XCTAssertEqual(AgentSearchField.missing(in: cloudflare), [.apiKey, .accountID])
        cloudflare.apiKey = "token"
        cloudflare.cloudflare = .init(accountID: validAccount, gatewayID: "bad gateway", byokAlias: "bad alias")
        XCTAssertEqual(AgentSearchField.missing(in: cloudflare), [.gatewayID, .byokAlias])
        cloudflare.cloudflare = .init(accountID: validAccount, gatewayID: "", byokAlias: "")
        XCTAssertEqual(AgentSearchField.missing(in: cloudflare), [], "An empty gateway means default")
        XCTAssertTrue(cloudflare.isConfigured, "No missing field must agree with the search configuration")

        XCTAssertEqual(AgentSearchField.apiKey.title(for: .cloudflare), L("ask.settings.search.cloudflare.token"))
        XCTAssertEqual(AgentSearchField.apiKey.title(for: .tavily), L("ask.settings.search.key"))
        XCTAssertEqual(AgentSearchField.accountID.title(for: .cloudflare), L("ask.settings.search.cloudflare.account"))
        XCTAssertEqual(AgentSearchField.gatewayID.title(for: .cloudflare), L("ask.settings.search.cloudflare.gateway"))
        XCTAssertEqual(AgentSearchField.byokAlias.title(for: .cloudflare), L("ask.settings.search.cloudflare.alias"))
    }
}
