# GUL-234 validation

Validated on the local macOS runner on 2026-10-07. Provider HTTP traffic uses
fixtures; no live paid generation was performed.

## Final focused run

```sh
CI=true swift test --no-parallel --enable-code-coverage \
  --filter 'AskImage|AskArtifact|AskScopedApproval|AskRecoveryWire|AskRecoveryProcess|StudioModels|AgentCapabilityStatus'
```

Passed: **86 XCTest tests + 49 Swift Testing tests**, no failures. This run was
performed after aligning the image settings with the existing Agent and Models UI.
The revision adds tests for immediate capability toggles without saving drafts,
change detection, failed saves retaining drafts, and light/dark rendering of advanced
options, success/error feedback and loading states for all five providers.

The four new suites cover all five providers, manual future model IDs, discovery,
stale refresh results, Keychain persistence, HTTP bounds/redirects/cancellation,
single paid POST semantics, download-only retries, task deadlines, approval
fingerprints, cloud/local receipts, cross-account storage and conversation deletion.

LLVM coverage for the six new `Ask/ImageGeneration/` files plus
`Settings/AskImageSettingsView.swift` and `Settings/AskImageSettingsModel.swift`:

| Scope | Line coverage |
| --- | ---: |
| Configuration | 100.00% |
| Generation service | 98.45% |
| HTTP transport | 96.43% |
| Model discovery | 95.40% |
| Settings and Keychain | 95.52% |
| Tool integration | 94.85% |
| Settings view | 94.80% |
| Settings model | 97.52% |
| Combined new module | **96.34% (1210 / 1256)** |

Combined region coverage: **90.59%**. These figures are scoped to the new module,
not the entire repository. Strict SwiftLint for the new production files,
SwiftFormat lint for the new production/test files, and `git diff --check` passed.
The five provider forms and their feedback states were rendered in light/dark mode;
Gemini, Bailian and OpenRouter screenshots are included
in the [feature documentation](../ask-image-generation.md).

## Full-suite limitation from the initial implementation

`make coverage` was attempted. A second attempt used
`CI=true swift test --no-parallel --enable-code-coverage`.
The second run's XCTest phase passed **2910 tests, with 9 CI skips and 0 failures**.
Both full attempts stalled in the Swift Testing phase. Process samples identified
`AskRecoveryRenderTests.snapshot` at line 119 waiting inside
`VNRecognizeTextRequest` / `VNCRImageReaderDetector`. The exact test child processes
were stopped after confirming the stalls; no full-suite pass is claimed.

The serial attempt also reported failures in these unchanged tests:

- `AskCappedWidthTests.shortModelNameHugsItsText`
- `AskComposerInteractionTests.voiceButtonClickAndHoldWorkInBothComposers`
- `AskSourceContextViewTests` (metadata/removal preview and narrow launcher layout)
- `AskComputerExecutorTests` (native display evidence: `needsObservation`)
- `AskComputerTargetProbeTests` (main-display geometry)
- `AskConversationWindowSizingTests` (requested viewport size)
- `AskLocalApprovalTests.desktopReadOnlyBindingsRemainAvailableWithoutAX`

The new settings-pane order assertion was updated and passes. No unmodified-HEAD
baseline run was performed, so the other failures are not classified as confirmed
baseline failures. Full-suite acceptance and real-provider smoke tests remain open;
the PR is a draft for review.
