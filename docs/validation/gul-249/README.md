# GUL-249 validation

The final focused run passed 16 XCTest cases and 135 Swift Testing cases.
The suites cover permission modes, commands, busy-composer keyboard handling,
responsive controls, read/write/MCP policy, screenshots, revocation, conversation
storage, local-engine reentrancy, cloud HTTP contracts, recovery, and preparation
failures. LLVM coverage for `AskPermissionMode.swift`: 100% lines/functions,
92.31% regions. All five localization files pass `plutil -lint`.

Run the focused checks with:

```sh
swift test --enable-code-coverage --no-parallel --filter 'Ask(PermissionModeTests|PermissionModeUITests|CommandRenderTests|CommandCatalogTests|SendQueueTests|ScopedApprovalTests|ScreenshotApprovalTests|ConversationTests|ConversationStorageTests|ComposerResponsiveTests|LocalEngineTests|LocalEngineReentrancyTests|APIClientTests|RecoveryInteractionTests|RecoveryNoticeInteractionTests|ToolPreparationTests)'
```

`permission-mode.png` is rendered from the actual composer after entering
`/mode yolo` while a Strict-mode file read waits for approval. The test verifies
one tool execution, one user message, and no command in chat history.

## Full-suite limitation

`make coverage` and a serial full run were attempted (3,016 XCTest cases and
1,668 Swift Testing cases). The full suite is not green. These five UI tests
also fail when `AskComposerViews.swift` is temporarily restored verbatim from
base commit `4235d7e8`; the feature implementation is restored afterward:

- `voiceButtonClickAndHoldWorkInBothComposers`: voice button position changes.
- `sourceChipPreviewsMetadataAndRemovalCanBeUndoneWithoutAScreenshot`: old source chip expectations.
- `narrowLauncherWrapsContentAndKeepsMemoryInTheFooter`: old source/selection chip expectations.
- `selectedTextPreviewCanRemoveOnlyTheSelection`: old selection chip expectation.
- `WorkflowOutputActionsVisualTests` / `menus open in popovers that nothing covers`: missing popover.

Approval-dependent fixtures explicitly select Strict. The interrupted/unknown
execution test retains an unacknowledged receipt and checks that resuming cannot
execute it twice; completed acknowledged history follows the existing recovery
presentation contract.

Deploy typeflux-api PR #116 across the serving endpoints before releasing the
client. Pre-upgrade active jobs need stop/retry to adopt the approval contract.
