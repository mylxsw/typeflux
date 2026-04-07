@testable import Typeflux
import XCTest

final class OnboardingProviderStyleTests: XCTestCase {
    func testListColumnWidthIsSlightlyNarrowerThanPreviousLayout() {
        XCTAssertEqual(OnboardingProviderStyle.listColumnWidth, 408)
        XCTAssertLessThan(OnboardingProviderStyle.listColumnWidth, 430)
    }

    func testMonochromeProvidersUseLightIconPlate() {
        let providers: [StudioModelProviderID] = [
            .openAI, .whisperAPI, .multimodalLLM, .openRouter, .grok, .groq, .groqSTT, .ollama,
        ]

        for provider in providers {
            XCTAssertEqual(OnboardingProviderStyle.iconPlateStyle(for: provider), .light)
        }
    }

    func testColorfulAndSymbolProvidersUseNeutralIconPlate() {
        let providers: [StudioModelProviderID] = [
            .aliCloud, .doubaoRealtime, .anthropic, .gemini, .freeSTT, .freeModel, .appleSpeech,
        ]

        for provider in providers {
            XCTAssertEqual(OnboardingProviderStyle.iconPlateStyle(for: provider), .neutral)
        }
    }
}
