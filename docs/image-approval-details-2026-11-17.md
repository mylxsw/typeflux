# Image approval details

Image generation and editing approvals now show a readable question, an existing task description (or a short prompt excerpt), and supplied ratio, resolution and model facts. Missing arguments are not invented. Local layout arguments use existing localized layout labels.

One disclosure, “View generation details”, replaces the duplicate raw JSON preview and technical block for image tools. Its body appears below its trigger and shows the complete decoded prompt with normal line breaks in a 240-point scrolling region. Copy raw parameters preserves the exact original JSON for diagnostics. The independent bottom action row retains existing deny, allow and approval-scope behavior.

Other tools retain their content previews; their technical disclosure now also precedes its body rather than expanding above a footer trigger. Permission policy and dispatch are unchanged.

## Validation

`make coverage SUITE="AskApprovalCopyTests AskActivityPresentationTests AskScopedApprovalTests"` passed 44 tests in 117.36 seconds including compilation and discovery. The scope covers approval copy and layouts, activity integration, and existing scoped authorization. File line coverage: AskApprovalCopy.swift 97.62%; AskApprovalViews.swift 72.24%. These are focused file figures, not changed-line or whole-project coverage.

Added checks cover decoded prompts longer than the old truncation limit, human-readable image facts, missing parameters, local layouts, 360/640-point card widths, bounded expanded height, and existing action callbacks. Native light/dark expanded/collapsed captures are in `validation/image-approval-details-2026-11-17/`; the dark expanded and light collapsed captures were visually reviewed. The screenshots use synthetic prompts. No paid image generation request was made.
