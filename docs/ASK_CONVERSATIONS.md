# Ask conversations

Double-tapping the Ask shortcut opens a centered, borderless composer. It does
not start recording or open the conversation workspace. Return submits;
Shift-Return inserts a newline; Return during IME composition does not submit.
Escape and clicking another application dismiss the composer while preserving
the draft. Existing dictation writes into its native NSTextView.

Submitting opens the workspace with history on the left, messages and tool
results on the right, and a follow-up composer. The menu also opens history.
The first question defaults to attaching a screenshot; follow-ups default to
text only. Attachments can be previewed, removed, or recaptured before sending.
Context is captured before the launcher takes focus. Removing a draft attachment
does not remove context already sent in previous messages.

Production views rendered with synthetic test data:

![Floating composer](images/ask-launcher.png)
![Conversation workspace](images/ask-workspace.png)
![Tool approval](images/ask-tool-approval.png)
![Dark workspace](images/ask-workspace-dark.png)
![Minimum-size workspace](images/ask-workspace-small.png)

## Approved continuous-conversation layout

The revised launcher is 640 pt wide and starts at 100 pt high. Its native editor
grows to 148 pt (216 pt panel) before scrolling, retaining that size when reopened.
It has no title bar or close button. Screenshot permission and retry actions live
beside the attachment controls, not in a separate oversized notice. The workspace
uses the existing StudioTheme palette and a 210 pt history sidebar, compact 38 pt
rows, regular body text, continuous left-aligned messages and collapsed tool details.
Both appearances and the 760 x 560 minimum window are covered by render tests.

Conversation selection has its own identity and loading/error states. Cached
content remains visible during refresh; an uncached target cannot accidentally
send as a new conversation. Late responses update their own cache without changing
the user's selection or drafts. Streaming updates replace a row in place instead
of moving it to the top. Pagination merges by conversation ID, never by title.
Reading anchors and drafts are retained separately for each conversation.

The released client generated uppercase UUID strings, while PostgreSQL returned
lowercase IDs in history summaries and retained uppercase IDs in JSON snapshots.
The revised wire models canonicalize conversation UUIDs to lowercase. Old SQLite
snapshots and drafts remain readable under either spelling; higher revisions win,
and deleting a conversation removes both local spellings and its tool journal.
No server migration or deletion of existing cloud history is required.

## Components

- `AskConversationWindowController` owns the launcher, workspace, and stop-control
  panel. `AppCoordinator` connects the existing hotkey and dictation workflows.
- `AskConversationModel` manages account state, history, drafts, cancellation,
  approval, and recovery. `AskAPIClient` uses the existing authenticated cloud
  transport; active conversations refresh once per second for streamed text.
- `AskConversationCache` stores account-scoped snapshots, drafts and a tool
  execution journal in SQLite under Application Support/Typeflux. Deleting a
  conversation removes its local draft and tool journal after cloud deletion.
- `AskContextCapture` uses accessibility and ScreenCaptureKit. Missing screen
  permission leaves the question usable without an attachment. Screenshots are
  JPEG, capped at 1600 pixels on the long edge and 2 MB. On macOS 14+, Typeflux
  windows are excluded from capture. macOS 13 uses the legacy on-screen capture.
- `AskLocalTools` exposes computer, Safari/Chrome browser, and configured MCP
  tools. Every invocation requires explicit approval. Computer/browser actions
  are bound to the application from which the question was opened. After an app
  restart that target is unavailable: start a new question from the target app.

## Recovery and execution

Stable message IDs make retries after a lost response idempotent. Unconfirmed
messages can be resumed after restart. Tool results are journaled before posting;
an interrupted execution with an unknown outcome is reported instead of replayed.
Approval rechecks the server run before any effect. Only one conversation can
control the desktop at a time. Cancellation blocks late answers and later local
actions; it cannot reverse actions already performed.

Closing an active workspace offers hide-and-continue or stop. Work continues
while the application is alive. Terminating the application does not create a
background agent: interrupted requests fail or expire and require deliberate
resume. Local history survives logout but is partitioned by account.

## Deployment and acceptance

Deploy the companion typeflux-api Ask routes and migration 00035 before shipping
this client. The default cloud model must support vision and tool calling.
Normal cloud credits, entitlements, and rate limits apply.

Focused tests use stubbed cloud/tool services and temporary SQLite files. Run:

```sh
swift test --filter 'Ask|WorkflowControllerProcessingTests.testAskShortcut'
TYPEFLUX_ASK_SNAPSHOTS="$PWD/ask-snapshots" swift test --filter AskConversationVisualTests
```

The opt-in visual suite renders production SwiftUI views and native windows with
synthetic content. It never records audio, captures the desktop, or operates a
real browser. Before release, verify on a signed app with a staging backend:

1. Double Fn shows only the composer, with focus; Fn dictation inserts into it.
2. Enter sends once, IME confirmation does not send, Shift-Enter adds a newline,
   Escape preserves the draft, and normal voice shortcuts retain their behavior.
3. Screenshot/selection preview and removal work on multiple monitors and with
   permissions denied; follow-ups do not attach a screenshot by default.
4. Conversation history, streaming, cancellation, retry and restart recovery work
   with the deployed model; switching accounts never displays the other history.
5. Approve a harmless browser read and screen capture; deny an action; stop during
   control. Safari/Chrome require Automation permission and their JavaScript from
   Apple Events setting; computer input requires Accessibility permission.
6. Verify configured MCP servers, including a disconnected or failing server.

English and Simplified Chinese strings are provided. The new Ask strings in
Japanese, Korean, and Traditional Chinese currently use English fallbacks except
for selected error messages; existing translated application strings are intact.

## Revision validation (2026-09-28)

- Focused instrumented run: 35 Swift Testing tests and 65 matching XCTest tests
  passed, including actual native-window focus, growing/reopened composers,
  IME behavior, uppercase legacy cache compatibility, ten consecutive follow-ups,
  delayed navigation, overlapping pagination, background tool completion, and
  reading-position restoration after history switching.
- LLVM source-line coverage from that run: model 92.96%, cache 92.80%, native
  composer 91.25%, wire models 96.77%. The six modified Swift production files
  together reach 87.45% (1937/2215), below the repository's 90% target; views are
  85.60% and the window controller is 79.01%. The entire Ask directory is 83.43%,
  including unchanged screen-capture and desktop-action adapters.
- Final full run through `make coverage`: 2669 XCTest tests, with 9 assertion
  failures in the same four pre-existing workflow tests below; all 120 Swift
  Testing tests passed. The coverage script exits at these failures, so the
  focused report above was extracted directly with llvm-profdata/llvm-cov.
- Existing failures are in `WorkflowControllerProcessingTests`:
  `testAudioPrefixSurvivesDelayedRealtimeSetupInOrder`,
  `testBeginRecordingStartsAudioBeforeRealtimeSessionSetupCompletes`,
  `testConnectivityFailureKeepsRecordingRetryableAndShowsPassiveNotice`, and
  `testLocalTranscriptIsAppliedWhenCloudASRIsCancelledAndRewriteFails`.
- Images show the production SwiftUI components with synthetic fixtures, not
  generated design mockups. Light/dark, permission notices, long text, tool
  approval and minimum-size windows were rendered and inspected.
- Signed-app/staging acceptance remains manual: these tests do not access a
  production account, live microphone, screen recording or real desktop tools.
