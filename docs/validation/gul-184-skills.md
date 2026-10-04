# GUL-184 validation

The final `make coverage` run passed, including both full test frameworks and HTML
report generation. Validated on macOS 26.6.2 / Apple Swift 6.4 on 2026-10-04 against base `f403fbe33cdcbe0bd14a7ff859661501d59778bb`.
P01 (#258) and P02 (#261) are merged. The change does not modify AskLocalEngine,
Memory, shared authorization DTOs, database migrations or API contracts.

## Behavior and test scope

The skill suites exercise commit-only tree/download requests, blob size/hash
verification, truncated and malformed API responses, unsafe paths, symlinks,
submodules, download/count/aggregate size limits, duplicate names, local alias
replacement, failure on the second new or replaced directory, preservation of an
existing backup during a failed update, rollback of source and resource files,
legacy metadata migration, disabled updates and re-enablement, and localized errors.

Parser cases include quotes, colons, comments, folded/literal blocks, paragraph
breaks, chomping, CRLF/BOM, permission lists, scalar metadata, malformed headers,
duplicate keys, invalid names, aliases, custom tags and unsupported nested values.

The authorization test loads a skill that asks to ignore prompts and declares
write/code permissions. Tool definitions, code/folder settings, risk classification
and the existing P02 approval binding remain unchanged. Disabled skills cannot be
loaded through AskLocalTools; update and rollback do not re-enable them.

## Test outcomes

- Final `make coverage`: exit 0; XCTest 2774 passed and 5 skipped (2779 reported),
  Swift Testing 748 passed in 101 suites. The skipped tests are not counted as passes.
- Skills plus AskAgentTools XCTest: 43 tests passed, including the explicitly
  enabled native settings screenshot fixture (31 skill-specific tests).
- AskHarnessUITests and AskScopedApprovalTests: 28 Swift Testing tests passed.
- Earlier plain `swift test`: XCTest 2779 tests, 5 skipped, no failures. Swift Testing ran 748
  tests; `recordingHintStaysCenteredAndFollowsTheCapsuleDuringMorphing` failed
  three layout assertions and returned exit 1. The final full coverage run passed.
- The first `make coverage` run also completed all 2779 XCTest tests (5 skipped)
  and 748 Swift Testing tests, but exited 2 after one assertion in that same
  overlay test failed. The later final full run passed without overlay code changes.
- A clean base worktree ran `swift test --enable-code-coverage`: XCTest 2756
  tests, 4 skipped, no failures; Swift Testing 748 tests with four assertions in
  `accountNameClickTogglesTheAccountCard` failing. These are fresh baseline results,
  not results inherited from an earlier task.
- The overlay test passed when run alone on both base and this branch. It failed
  again when grouped with other UI suites. Its cause remains unconfirmed; this
  report does not claim the full-suite failure is fixed or proven pre-existing.
- Core skill production files and all skill test files pass strict SwiftLint.
  The shared settings view retains its existing long-line and long-type warnings.

The extra standard-run skip is the opt-in screenshot test; it was run explicitly
with `TYPEFLUX_SKILL_SNAPSHOTS=docs/design/ask-skills`. Screenshots use production
AppKit/SwiftUI views and synthetic data, and were visually inspected in both
appearances: [light](../design/ask-skills/skills-light.png),
[dark](../design/ask-skills/skills-dark.png).

## Coverage

Coverage includes executed tests even when another UI test fails; it is not a
claim that the command passed. When `make coverage` exits before report generation,
both that run's XCTest and Swift Testing `.profraw` files are merged with
`xcrun llvm-profdata merge -sparse`, then reported with `xcrun llvm-cov report`.
Dependencies, generated `.build` files and tests are excluded from the whole-source
measurement using the repository script's `.build|Tests` exclusion.

Final full-run coverage (not just the selected skill tests):

| Production file | Line coverage | Region coverage |
| --- | ---: | ---: |
| AskSkillInstaller.swift | 98.42% | 97.46% |
| AskSkillInstaller+GitHub.swift | 97.84% | 94.44% |
| AskSkillInstallationStore.swift | 97.25% | 90.00% |
| AskSkillSource.swift | 100.00% | 100.00% |
| AskSkillParser.swift | 97.58% | 96.00% |
| AskSkills.swift | 98.67% | 92.86% |
| Combined skill core | **98.00% (734/749)** | **94.81%** |

Whole production-source line coverage: fresh base **54.08% (71,415/132,044)**;
final branch **54.24% (71,878/132,512)**. The whole-source baseline did not decrease.
The 98% scope is the six core files above, not the full repository or settings view.

## Limits and review status

- Earlier UI failures remain documented even though the final full run passed.
  Full-suite UI stability is not established by one passing run. CI is not part of
  these local results, and merge/acceptance remain with the reviewer.
- Resource/network behavior uses URLProtocol fixtures. Real GitHub rate limits,
  live branch mutations over the network, real model/MCP execution, databases and
  the complete desktop/browser permission matrix were not exercised.
- Atomic filesystem publication was exercised on macOS. Unsupported filesystems,
  external editors racing installation and power-loss durability are not claimed.
- A full library snapshot costs temporary disk space. Abrupt process termination
  can leave an ignored sibling snapshot; live publication stays atomic.

The supported YAML subset, Yams/CYaml dependency cost and MIT notices, metadata
migration and explicit overwrite/removal semantics are documented in
[the installation contract](../ask-skills.md).
