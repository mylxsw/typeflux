# macOS stability hardening

This delivery isolates clipboard history capture, bounds command/workflow execution,
and lets the launcher start when conversation storage is unavailable. It is the
first implementation of the approved stability design, not a guarantee against
arbitrary crashes in the remaining AppKit, audio, model, or storage code.

## Protection boundaries

- `ManagedProcess` owns the child process group until its final signal, uses a
  monotonic deadline, drains both output streams fairly, and handles nonblocking
  stdin without SIGPIPE. A shared reaper limits live or unreaped children to 16;
  an uninterruptible child cannot hold its caller in a blocking `waitpid`.
- `ProcessCommandRunner` retains inherited environment/override and raw output
  semantics, with a 900-second default deadline and a 16 MiB per-stream limit.
  Interactive system commands use 60 seconds and 200,000 bytes. Exceeding the
  output limit is an explicit failure, never a successful partial result.
- `AskWorkflowRunner` uses the same lifecycle, preserves stdin and cumulative
  line progress, and keeps at most two pending events. Normal exit immediately
  cleans remaining group members; cancellation retains the termination grace.
  Processes that deliberately escape their group require separate containment.
- The production clipboard monitor launches the existing app executable in
  `clipboard-capture-worker` mode. Full pasteboard reads and bitmap decoding run
  there, before application startup. Clipboard content travels through bounded
  stdout, never command arguments. The parent validates response version, copy
  generation and payload budgets. It skips a failed copy and creates a fresh child
  for a subsequent eligible copy. Failures back off and eventually open a circuit.
- Clipboard capture allows at most two queued/active snapshots. Encoded images
  are limited to 32 MiB, normalized PNG to 10 MiB, dimensions to 16,384 per axis
  and 16 million pixels, text/combined file URLs to 1 MiB, and files to 1,000.
  Stop, disable, or capture suppression invalidates queued results. Polling the
  pasteboard change counter and rendering history previews remain in the host.
- `RecoveringAskConversationCache` opens the real SQLite cache lazily from its
  actor. Connection failures delay later attempts by 1/2/4 seconds; a fourth
  failure in 60 seconds opens a five-minute circuit. It never substitutes an
  empty journal or automatically repeats an operation. In-flight operations
  finish before a failed connection is discarded. Binding/approval errors do not
  reopen the database. The launcher can operate while cache calls fail explicitly.

## Source relationships

`DIContainer` selects the clipboard worker; `TypefluxCLI/main.swift` dispatches its
private command. `ClipboardMonitor` owns capture admission and generation checks;
`ClipboardCaptureWorker` owns process transport and recovery policy; capture rules
validate dimensions before decoding. `ProcessCommandRunner`, workflow execution,
the clipboard worker and existing Agent clients share `ManagedProcess` and its
bounded reaper. Conversation-window construction now depends on `AskCaching` and
the lazy recovery adapter rather than opening SQLite synchronously.

## Validation scope

| Changed behavior or caller | Suites |
| --- | --- |
| Process deadlines, output floods, SIGPIPE, cleanup and admission | ProcessCommandRunnerTests, ManagedProcessTests, OwnedProcessReaperTests |
| Workflow execution, cancellation, slow consumer and plugin results | AskWorkflowRunnerTests, AskWorkflowPluginTests |
| Real clipboard child, malformed response, crash/recovery, input budgets and stale capture | ClipboardCaptureWorkerTests, ClipboardMonitorTests, ClipboardCaptureRulesTests |
| Existing Agent process clients | AskAutomationScriptRunnerTests, AskCodeSandboxTests |
| Command/transcriber callers and environment/output compatibility | AskSystemCommandTests, LocalModelTranscriberTests, OllamaModelDownloadAnalyticsTests |
| Recovery budget, persistent execution claims and launcher degradation | ModuleRecoveryBudgetTests, RecoveringAskConversationCacheTests, AskRecoveryJournalTests, AskConversationWindowServicesTests, AskOpenChatTests |

Fault fixtures kill only their own child processes. Tests do not crash the XCTest
host or send real shutdown/restart commands. Clipboard integration uses isolated
named pasteboards, and storage failures use disposable databases and triggers.

Final validation on macOS arm64 with Apple Swift 6.4 passed **171 test methods**
(109 XCTest and 62 Swift Testing methods in the 18 suites above).
Changed executable Swift lines: **543 / 568 = 95.60%**, measured by intersecting
`git diff --unified=0` added lines with LLVM's executable line counts. The detailed
per-file counts are in `changed-line-coverage.json`. This exceeds the 90% changed
code target. Project-wide line coverage from this focused run was **9.91%**;
that is not a full-project test result.

The host profile does not include `TypefluxCLI/main.swift`. The real-child tests
exercise that entrypoint and clipboard decoding in a separate executable, whose
counts are not merged into the host profile. This also explains the worker file's
83.33% host-only changed-line coverage. The process adapter, reaper, clipboard
capture rules, clipboard admission budget and recovery budget each have 100%
changed-line coverage. Changed `ManagedProcess` lines have 97.89%; the recovering
conversation cache has 95.96%.

Targeted SwiftLint checks passed for the 11 core implementation files, and
`git diff --check` passed. Existing unrelated compiler warnings remain.

### Validation timing and retries

All times below include command startup and preparation, except where explicitly
identified as approximate. No full test suite was run.

| Invocation | Total wall time | Result |
| --- | ---: | --- |
| Initial focused discovery/build plan | 330.60 s | Built; no tests executed |
| Original focused coverage command | 433.73 s | Two existing UI methods failed; all new fault tests passed |
| Retry of the two containing UI suites | 27.27 s | Reproduced the two failures |
| Same UI suites after fixture timing fixes | 47.87 s | 28 methods passed; coverage command still failed without a profile |
| Native-backend attempt through the discovery runner | 484.66 s | All 171 methods passed; coverage command still failed without a profile |
| Explicit native instrumented build | approximately 343.61 s | Build passed; verified LLVM coverage sections in the binary |
| Final prebuilt instrumented run, including profile generation | 81.35 s | All 171 methods passed; command exit 0 and valid merged profile |

The two UI fixture fixes wait for a current plugin plan and put a new confirmation
attempt outside the existing 250 ms duplicate-activation guard. They do not weaken
the assertions or change production activation behavior.

The toolchain's `swift test ... list` discovery path left uninstrumented objects
despite the requested coverage setting. Changing build backends alone did not fix
it. Final measurement explicitly built the instrumented targets, verified their
LLVM sections, and ran them without another discovery build:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel \
  --filter '^TypefluxTests[./](ProcessCommandRunnerTests|ManagedProcessTests|OwnedProcessReaperTests|AskWorkflowRunnerTests|AskWorkflowPluginTests|ClipboardMonitorTests|ClipboardCaptureRulesTests|ClipboardCaptureWorkerTests|AskAutomationScriptRunnerTests|AskCodeSandboxTests|AskSystemCommandTests|LocalModelTranscriberTests|OllamaModelDownloadAnalyticsTests|ModuleRecoveryBudgetTests|RecoveringAskConversationCacheTests|AskConversationWindowServicesTests|AskRecoveryJournalTests|AskOpenChatTests)[./]'
```

The final invocation used the repository runner's sanitized child environment.
LLVM reports used the native `TypefluxPackageTests` binary and
`.build/arm64-apple-macosx/debug/codecov/default.profdata`. No source changes were
made after that successful run.

## Remaining implementation

The approved follow-up work includes a complete module lifecycle supervisor,
recoverable notebook/word-book stores, broader native-call isolation, and moving
in-process model/audio work behind validated helper boundaries. Audio/TCC/signing,
sleep/wake, device removal, and real signed-app latency/memory still need device
validation. This change does not install a global exception or signal handler
that resumes execution after an unsafe crash.

Opening working directories and spawning still involve host kernel calls. A
deadline can bound child execution and pipe cleanup, but cannot forcibly unwind
an uninterruptible syscall in the host. Clipboard change-count polling, history
preview rendering and SQLite also retain host-native boundaries. The later
supervisor/helper work must account for these remaining failure domains.
