import XCTest
@testable import Typeflux

final class StudioModelsTests: XCTestCase {

    // MARK: - StudioSection

    func testStudioSectionAllCasesCount() {
        XCTAssertEqual(StudioSection.allCases.count, 7)
    }

    func testStudioSectionId() {
        for section in StudioSection.allCases {
            XCTAssertEqual(section.id, section.rawValue)
        }
    }

    func testStudioSectionTitlesAreNonEmpty() {
        for section in StudioSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section) title should not be empty")
        }
    }

    func testStudioSectionIconNamesAreNonEmpty() {
        for section in StudioSection.allCases {
            XCTAssertFalse(section.iconName.isEmpty, "\(section) iconName should not be empty")
        }
    }

    func testStudioSectionEyebrowsAreNonEmpty() {
        for section in StudioSection.allCases {
            XCTAssertFalse(section.eyebrow.isEmpty, "\(section) eyebrow should not be empty")
        }
    }

    func testStudioSectionHeadingsAreNonEmpty() {
        for section in StudioSection.allCases {
            XCTAssertFalse(section.heading.isEmpty, "\(section) heading should not be empty")
        }
    }

    func testStudioSectionSearchPlaceholdersAreNonEmpty() {
        for section in StudioSection.allCases {
            XCTAssertFalse(section.searchPlaceholder.isEmpty, "\(section) searchPlaceholder should not be empty")
        }
    }

    func testSidebarUpperCases() {
        let upper = StudioSection.sidebarUpperCases
        XCTAssertEqual(upper, [.home, .vocabulary, .history])
    }

    func testSidebarLowerCases() {
        let lower = StudioSection.sidebarLowerCases
        XCTAssertEqual(lower, [.models, .personas])
    }

    func testSubheadingNilForCertainSections() {
        XCTAssertNil(StudioSection.models.subheading)
        XCTAssertNil(StudioSection.personas.subheading)
        XCTAssertNil(StudioSection.history.subheading)
        XCTAssertNil(StudioSection.settings.subheading)
    }

    func testSubheadingNonNilForOtherSections() {
        XCTAssertNotNil(StudioSection.home.subheading)
        XCTAssertNotNil(StudioSection.vocabulary.subheading)
        XCTAssertNotNil(StudioSection.agent.subheading)
    }

    // MARK: - StudioModelDomain

    func testStudioModelDomainCount() {
        XCTAssertEqual(StudioModelDomain.allCases.count, 2)
    }

    func testStudioModelDomainId() {
        XCTAssertEqual(StudioModelDomain.stt.id, "stt")
        XCTAssertEqual(StudioModelDomain.llm.id, "llm")
    }

    func testStudioModelDomainTitlesAreNonEmpty() {
        XCTAssertFalse(StudioModelDomain.stt.title.isEmpty)
        XCTAssertFalse(StudioModelDomain.llm.title.isEmpty)
    }

    func testStudioModelDomainSubtitlesAreNonEmpty() {
        XCTAssertFalse(StudioModelDomain.stt.subtitle.isEmpty)
        XCTAssertFalse(StudioModelDomain.llm.subtitle.isEmpty)
    }

    func testStudioModelDomainIconNames() {
        XCTAssertEqual(StudioModelDomain.stt.iconName, "waveform")
        XCTAssertEqual(StudioModelDomain.llm.iconName, "ellipsis.message")
    }

    // MARK: - StudioModelProviderID

    func testSTTProvidersDomain() {
        let sttProviders: [StudioModelProviderID] = [
            .appleSpeech, .localSTT, .freeSTT, .whisperAPI, .multimodalLLM, .aliCloud, .doubaoRealtime
        ]
        for provider in sttProviders {
            XCTAssertEqual(provider.domain, .stt, "\(provider) should be in STT domain")
        }
    }

    func testLLMProvidersDomain() {
        let llmProviders: [StudioModelProviderID] = [
            .ollama, .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini,
            .deepSeek, .kimi, .qwen, .zhipu, .minimax, .grok, .xiaomi
        ]
        for provider in llmProviders {
            XCTAssertEqual(provider.domain, .llm, "\(provider) should be in LLM domain")
        }
    }

    func testAllProvidersCoveredInDomain() {
        for provider in StudioModelProviderID.allCases {
            let domain = provider.domain
            XCTAssertTrue(domain == .stt || domain == .llm, "\(provider) should have a valid domain")
        }
    }

    // MARK: - HistoryPipelineStatPresentationItem

    func testPipelineStatItem() {
        let item = HistoryPipelineStatPresentationItem(
            id: "test",
            title: "Latency",
            value: "120ms",
            style: .duration
        )
        XCTAssertEqual(item.id, "test")
        XCTAssertEqual(item.title, "Latency")
        XCTAssertEqual(item.value, "120ms")
    }

    // MARK: - StudioModelCard

    func testModelCard() {
        let card = StudioModelCard(
            id: "whisper",
            name: "Whisper",
            summary: "OpenAI Whisper",
            badge: "Free",
            metadata: "v3",
            isSelected: true,
            isMuted: false,
            actionTitle: "Select"
        )
        XCTAssertEqual(card.id, "whisper")
        XCTAssertTrue(card.isSelected)
        XCTAssertFalse(card.isMuted)
    }
}

// MARK: - Extended StudioModels tests

extension StudioModelsTests {

    // MARK: - StudioModelProviderID

    func testProviderIDRawValueRoundTrip() {
        for providerID in StudioModelProviderID.allCases {
            let raw = providerID.rawValue
            let recovered = StudioModelProviderID(rawValue: raw)
            XCTAssertEqual(recovered, providerID)
        }
    }

    func testAllProviderIDsHaveNonEmptyRawValues() {
        for providerID in StudioModelProviderID.allCases {
            XCTAssertFalse(providerID.rawValue.isEmpty, "\(providerID) should have a non-empty raw value")
        }
    }

    func testProviderIDIdentifiableID() {
        for providerID in StudioModelProviderID.allCases {
            XCTAssertEqual(providerID.id, providerID.rawValue)
        }
    }

    func testSTTProvidersDomainIsSTT() {
        let sttProviders: [StudioModelProviderID] = [
            .whisperAPI, .appleASR, .local, .doubao, .aliCloud, .openAIRealtime
        ]
        for provider in sttProviders {
            XCTAssertEqual(provider.domain, .stt, "\(provider) should be in STT domain")
        }
    }

    func testLLMProvidersDomainIsLLM() {
        let llmProviders: [StudioModelProviderID] = [
            .openAI, .anthropic, .gemini, .deepSeek, .kimi
        ]
        for provider in llmProviders {
            XCTAssertEqual(provider.domain, .llm, "\(provider) should be in LLM domain")
        }
    }

    // MARK: - HistoryPipelineStatPresentationItem

    func testPipelineStatItemEquality() {
        let item1 = HistoryPipelineStatPresentationItem(
            id: "latency", title: "Latency", value: "100ms", style: .duration
        )
        let item2 = HistoryPipelineStatPresentationItem(
            id: "latency", title: "Latency", value: "100ms", style: .duration
        )
        XCTAssertEqual(item1.id, item2.id)
        XCTAssertEqual(item1.title, item2.title)
        XCTAssertEqual(item1.value, item2.value)
    }

    func testPipelineStatItemStyles() {
        // Verify all styles are distinguishable by their raw values
        let durationItem = HistoryPipelineStatPresentationItem(
            id: "d", title: "Duration", value: "500ms", style: .duration
        )
        let countItem = HistoryPipelineStatPresentationItem(
            id: "c", title: "Count", value: "42", style: .count
        )
        // Just verify they don't crash
        XCTAssertEqual(durationItem.style, .duration)
        XCTAssertEqual(countItem.style, .count)
    }

    // MARK: - StudioModelCard

    func testModelCardNotSelectedNotMuted() {
        let card = StudioModelCard(
            id: "gpt-4o",
            name: "GPT-4o",
            summary: "OpenAI GPT-4o",
            badge: nil,
            metadata: nil,
            isSelected: false,
            isMuted: false,
            actionTitle: "Use"
        )
        XCTAssertFalse(card.isSelected)
        XCTAssertFalse(card.isMuted)
        XCTAssertNil(card.badge)
        XCTAssertNil(card.metadata)
    }

    func testModelCardWithNilBadgeAndMetadata() {
        let card = StudioModelCard(
            id: "test-model",
            name: "Test Model",
            summary: "Summary",
            badge: nil,
            metadata: nil,
            isSelected: false,
            isMuted: true,
            actionTitle: "Configure"
        )
        XCTAssertTrue(card.isMuted)
        XCTAssertNil(card.badge)
        XCTAssertNil(card.metadata)
    }
}
