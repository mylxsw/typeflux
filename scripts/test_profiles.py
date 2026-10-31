"""Audited test-source closures; execution still uses actual discovery and filters."""

PROFILES = {
    "calculator": {
        "files": ["AskCalculatorTests.swift", "AskCalculatorFormatsTests.swift"],
        "suites": ["AskCalculatorDetectionTests", "AskCalculatorEvaluationTests", "AskCalculatorLexerTests",
                   "AskCalculatorFormatsTests", "AskCalculatorNumberTests"],
    },
    "scroll": {
        "files": ["ScrollStitcherTests.swift", "DirectionalScrollStitcherTests.swift", "ScrollCaptureFixtures.swift"],
        "suites": ["ScrollStitcherTests", "DirectionalScrollStitcherTests"],
    },
    "overlay": {
        "files": ["OverlayTransitionRenderingTests.swift", "BitmapTestPixelsTests.swift",
                  "BitmapTestPixels.swift", "ExclusiveUIStateTrait.swift"],
        "suites": ["OverlayTransitionRenderingTests", "BitmapTestPixelsTests"],
    },
    "retry": {
        "files": ["RequestRetryTests.swift", "ConnectionTestSupportTests.swift"],
        "suites": ["RequestRetryTests", "ConnectionTestSupportTests"],
    },
    "speech-llm": {
        "files": ["OnboardingSpeechLLMTests.swift", "OnboardingSpeechBehaviorTests.swift",
                  "OnboardingLLMBehaviorTests.swift", "OnboardingSpeechLLMCaptureTests.swift",
                  "OnboardingProviderControlTests.swift",
                  "SettingsBehaviorTestSupport.swift", "ExclusiveUIStateTrait.swift"],
        "suites": ["OnboardingSpeechLLMTests"],
    },
}


def selected_profile_files(suites, explicit=None):
    """Unknown scopes keep the normal source set; never infer fixture dependencies."""
    if explicit:
        profile = PROFILES[explicit]
        if any(suite not in profile["suites"] for suite in suites):
            raise ValueError("A requested suite is outside the selected build profile")
        return sorted(profile["files"])
    owners = {suite: name for name, profile in PROFILES.items() for suite in profile["suites"]}
    if not suites or any(suite not in owners for suite in suites):
        return None
    return sorted({file for suite in suites for file in PROFILES[owners[suite]]["files"]})
