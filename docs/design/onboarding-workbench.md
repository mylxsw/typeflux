# Onboarding workbench

Layout reference: [option 3](../evidence/onboarding-workbench/selected-design.png). The visual scale is now anchored to the existing welcome page, as corrected by the user; the generated board is not the type/control-size reference.

The service setup pages use a persistent progress rail and one task area. The native window remains 960 × 664 points. The rail is 208 points wide; the main area has 40-point horizontal insets. Footers stay inside the window with at least 28 points below their primary action.

## Service choice

Recommend Typeflux Cloud; keep custom services and the launcher-only path visible. The selected row has its own radio indicator and tint. Existing model connections survive a skip. The launcher explanation reflects which services are actually missing.

## Cloud

The signed-out page has one primary action, **Sign in and continue**, opening the existing login window. Subscription refresh determines the services available to the account. No Cloud speech entitlement is assumed. An account without Cloud speech proceeds to speech setup; custom/local services remain account-free alternatives.

## Custom services

Speech recognition comes before the language model. Both pages reuse the existing model editors. The speech field keeps the native menu bridge and keyboard behavior while using the selected design's inset field shape. A configured remote service shows **Not verified** until its connection test passes. **Test and continue** advances only after successful verification; failures remain visible and retryable.

Back, Skip, opening an editor, and changing the selected model cancel pending navigation. Changing speech services cancels and clears the shared editor's previous test. Updating language connection details invalidates the previous verification signature.

## Skip and recovery

Skipping requires a concise capability explanation and confirmation. Existing configuration is retained. Skipped progress stages use a minus indicator rather than a completion check.

Recovery stays available from the finish summary, the menu bar's **Continue setup…**, feature-specific missing-configuration actions, and Settings → Models. Model setup and Cloud sign-in use the same existing windows in each entry path. Missing models do not disable launcher search.

## Validation scope

- `OnboardingViewModelTests`: routing, configuration prerequisites, combined validation actions, stale results, deferral and recovery state.
- `OnboardingBehaviorTests`: native controls, editor/login entry points, both appearances, Chinese/English rendering and footer bounds.
- `OnboardingFeatureTests`: existing guide and permission dependencies.
- `CloudLoginSyncCoordinatorTests`: account entitlement and existing model selection handoff.
- Five focused `WorkflowControllerProcessingTests`: missing speech configuration, account-free recovery and missing language-model guards.

Visual comparisons and final validation evidence are recorded in [design-qa.md](../../design-qa.md).

## Welcome-page scale correction

The previous implementation enlarged setup typography and controls beyond the welcome page. Keep the workbench structure, but use the existing interface scale:

- Configuration headings: 26 points, semibold; the welcome's 34-point headline remains the introductory hero.
- Supporting copy: 14 points; regular text and fields: 13 points; option titles: 15 points.
- Primary and secondary footer actions: the same `StudioButton` used on the welcome and guide pages, with no separate setup button style or minimum width.
- Selection rows: 88 points instead of 116; speech field: 34 points instead of 42.
- Cloud handoff artwork: 56-point product icon, matching the welcome icon; 48-point account symbol.
- Rail labels: 12.5 points, with quiet 11.5-point support text.

Review welcome → service choice → Cloud → speech → language → permissions → finish as one native flow at the same window size. A generated board by itself is insufficient acceptance evidence. Regression checks compare the actual welcome primary-action height with subsequent pages and bound selection-row height relative to that baseline.
