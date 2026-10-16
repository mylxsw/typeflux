# GUL-399 merge audit and main integration

Audit performed on 2026-10-16. The member asked why several PRs closed during merging and whether any implementation was left unmerged.

## Findings

- At audit time, `origin/main` was `c24442eda6bce4b70b82c04054914952adec6114`. Of the 20 delivered increments, only #511 was an ancestor of main. All 20 original implementation commits are ancestors of #533 (`1f5a8654b0c634d6e75702fc79ae16cb701ccc56`). No original increment was lost.
- GitHub records `BaseRefDeletedEvent` immediately followed by `ClosedEvent` for #512, #516, #518, #521 and #524. Each PR targeted the preceding feature branch. Deleting that base closed the dependent PR; this was not a successful merge into main.
- The repository currently reports `delete_branch_on_merge: false`. The events prove base deletion followed by closure; they do not prove that deleting the base itself was automatic. No repository deletion/merge settings were changed.
- The other merged PRs targeted intermediate feature branches. A merged badge therefore did not establish that their code reached main. For every surviving merged base, there are no non-merge commits absent from #533; all additional merge commits have a tree identical to their implementation parent. No extra merge-resolution edits need rescuing.
- This delivery creates a single integration branch based on the actual main tip and locally merges #533. It preserves all original commits and main-only work. It does not merge any GitHub PR or change existing PR bases. #532/#533 remain useful incremental review history; the integration PR is the main landing entry point.

## Commit inventory

| PR | GitHub state at audit | Actual base | Original commit | In main | In #533 |
| --- | --- | --- | --- | --- | --- |
| [#511](https://github.com/mylxsw/typeflux/pull/511) | MERGED | `main` | `1b5b3fc6` | yes | yes |
| [#512](https://github.com/mylxsw/typeflux/pull/512) | CLOSED | `agent/arch-gpt-astra/8a073f2cdbb3` | `69ce9fab` | no | yes |
| [#514](https://github.com/mylxsw/typeflux/pull/514) | MERGED | `agent/arch-gpt-astra/gul-399-supervisor` | `7e2e6b80` | no | yes |
| [#516](https://github.com/mylxsw/typeflux/pull/516) | CLOSED | `agent/arch-gpt-astra/gul-399-wordbook` | `d68b035d` | no | yes |
| [#517](https://github.com/mylxsw/typeflux/pull/517) | MERGED | `agent/arch-gpt-astra/gul-399-notebook` | `eb5700e2` | no | yes |
| [#518](https://github.com/mylxsw/typeflux/pull/518) | CLOSED | `agent/arch-gpt-astra/gul-399-health-registry` | `2ca136aa` | no | yes |
| [#519](https://github.com/mylxsw/typeflux/pull/519) | MERGED | `agent/arch-gpt-astra/gul-399-recovery-ui` | `46d76c66` | no | yes |
| [#521](https://github.com/mylxsw/typeflux/pull/521) | CLOSED | `agent/arch-gpt-astra/gul-399-native-commands` | `e34406bf` | no | yes |
| [#522](https://github.com/mylxsw/typeflux/pull/522) | MERGED | `agent/arch-gpt-astra/gul-399-whisper-worker` | `566ae1cb` | no | yes |
| [#523](https://github.com/mylxsw/typeflux/pull/523) | MERGED | `agent/arch-gpt-astra/gul-399-media-worker` | `8943cb5c` | no | yes |
| [#524](https://github.com/mylxsw/typeflux/pull/524) | CLOSED | `agent/arch-gpt-astra/gul-399-media-preview` | `1148a8c2` | no | yes |
| [#525](https://github.com/mylxsw/typeflux/pull/525) | MERGED | `agent/arch-gpt-astra/gul-399-av-preview` | `6d2164a0` | no | yes |
| [#526](https://github.com/mylxsw/typeflux/pull/526) | MERGED | `agent/arch-gpt-astra/gul-399-artifact-images` | `26adbbf7` | no | yes |
| [#527](https://github.com/mylxsw/typeflux/pull/527) | MERGED | `agent/arch-gpt-astra/gul-399-typed-images` | `c030a9f2` | no | yes |
| [#528](https://github.com/mylxsw/typeflux/pull/528) | MERGED | `agent/arch-gpt-astra/gul-399-generated-images` | `3cd582dd` | no | yes |
| [#529](https://github.com/mylxsw/typeflux/pull/529) | MERGED | `agent/arch-gpt-astra/gul-399-generation-recovery` | `bd5e6f92` | no | yes |
| [#530](https://github.com/mylxsw/typeflux/pull/530) | MERGED | `agent/arch-gpt-astra/gul-399-remote-images` | `37e8a0f2` | no | yes |
| [#531](https://github.com/mylxsw/typeflux/pull/531) | MERGED | `agent/arch-gpt-astra/gul-399-context-images` | `90ac223c` | no | yes |
| [#532](https://github.com/mylxsw/typeflux/pull/532) | OPEN | `agent/arch-gpt-astra/gul-399-context-images` | `d4e308c0` | no | yes |
| [#533](https://github.com/mylxsw/typeflux/pull/533) | OPEN | `agent/arch-gpt-astra/gul-399-small-icons` | `1f5a8654` | no | yes |

## Confirmed closure timeline (UTC)

| PR | Base deletion | Closure |
| --- | --- | --- |
| #512 | 2026-10-16T00:28:22Z | 2026-10-16T00:28:23Z |
| #516 | 2026-10-16T00:29:07Z | 2026-10-16T00:29:08Z |
| #518 | 2026-10-16T00:29:40Z | 2026-10-16T00:29:41Z |
| #521 | 2026-10-16T00:30:17Z | 2026-10-16T00:30:18Z |
| #524 | 2026-10-16T00:31:19Z | 2026-10-16T00:31:20Z |

Evidence was collected using `gh api graphql` (`BaseRefDeletedEvent` and `ClosedEvent`), `gh pr list`, `multica issue pull-requests`, and a fresh `git fetch origin --prune`. Ancestry was checked with `git merge-base --is-ancestor` for each full original commit.

## Integration review

- Common ancestor comparison identified 150 main-only paths and 262 stability-only paths. Each resulting path is byte-for-byte identical to its respective parent (including additions/removals).
- Eight paths changed on both sides. Three Swift files merged automatically: `AskComposerViews.swift`, `AskConversationModel+Plugins.swift`, and `AskPluginSession.swift`. Review confirmed main’s semantic search registration, input tracing, live-result selection and prewarm lifecycle coexist with stability’s image scopes, generation rejection, async storage and no-replay behavior.
- Five localization files conflicted only at appended blocks. Both blocks were retained. Every parsed key/value pair from both parents was verified present with the same value; all five files pass `plutil -lint`.
- `git diff --cached --check` passed. No new executable behavior was authored for this integration; manual resolution only combines existing localization entries. Coverage percentages from prior increments are historical evidence, not fresh validation of this merge.

## Fresh validation

The final integrated tree passed a fresh instrumented build and **53 distinct focused methods** (21 XCTest + 32 Swift Testing), with no functional failures or retries. The semantic invalid-query method includes seven argument cases.

- `AskPluginSessionTests` (9) and `AskSemanticFileSearchPluginTests` (8): the automatically merged plugin/session/registration paths, including real launcher selection and stale results.
- `AskContextImageTests` (11) and `NativeIconIsolationTests` (9): scoped image ownership/privacy and the latest helper boundary alongside main's launcher changes; synthetic fixtures and harmless disposable children only.
- `ModuleSupervisorTests` (13): bounded startup, cancellation, retained operations, recovery without effect replay and shutdown.
- `LocalizationResourceTests/testLocalizedStringTablesParseForAllSupportedLanguages` (1): merged resource parsing.
- `AskPermissionModeTests/policyMatrixAndExactCommands` and `commandsStayLocalAndNewConversationsReset` (2): consent/local mode compatibility.

Commands used `scripts/test_runtime.child_environment()` to remove runtime credentials:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<scope below>'
```

```text
^Typeflux(?:Focused)?Tests[./](?:(?:AskPluginSessionTests|AskSemanticFileSearchPluginTests|NativeIconIsolationTests|AskContextImageTests|ModuleSupervisorTests)[./]|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages|AskPermissionModeTests[./](?:policyMatrixAndExactCommands|commandsStayLocalAndNewConversationsReset))
```

Build wall time: **263.24 s**. Focused test command: **14.53 s**. Total build/test: **277.77 s**; audit, profile verification and review are additional. Both the test executable and helper contained `__llvm_covmap` and `__llvm_prf_cnts`. No test discovery rebuild occurred between build and test. All 12 fresh raw profiles were individually validated and merged without warnings after children exited. No earlier profiles/results were reused. Matching binaries/profiles are saved task-locally under `.build/main-integration-validation`.

This integration introduces no new executable lines beyond the existing parent implementations, so no new changed-line percentage is asserted. The focused pass is integration evidence, not a rerun of every historical increment's scope.

SHA-256:

- XCTest: `e05ed54d2e1f71ea4a65a553bb6a40683939a13795ab56e9b496172c0b87c3d7`
- Media helper: `4f88abcf9f6db47b2de7c70b8d0303cd841bde4ee12130804959279eeeae2cfa`

## Remaining boundaries

This is a landing-path repair for delivered increments, not completion of GUL-399. Context application badges, preview-header native icons, Quick Look boundaries, further lifecycle/health integration, and audio/TCC/signing/performance decisions remain. Existing per-increment reports retain their explicit hardware/native API/real-model limits. No full suite, paid provider, live capture, TCC, release signing, or real hardware validation is implied.
