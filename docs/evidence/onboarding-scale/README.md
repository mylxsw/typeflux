# Onboarding scale correction

The welcome page is the reference for typography and control scale. The selected workbench arrangement remains the layout reference. Native window size: 960 × 664 points; original captures: 1920 × 1328 pixels.

## Sources and installed-app inspection

- `baseline-welcome.png`: user-supplied welcome baseline.
- `services-before.png`, `cloud-before.png`: user-supplied oversized setup pages.
- `native-welcome.png`, `native-services.png`, `native-cloud.png`, `native-speech.png`, `native-finish.png`: captures from the rebuilt installed Typeflux Dev app.

The installed flow was inspected continuously through service choice, Cloud, speech, language, permissions, existing feature guides, and finish. Native editors/login/routing remain shared with the previous implementation. No account sign-in was completed, and no credentials or model endpoints were edited during this visual correction. Scoped onboarding/language/appearance preferences were restored before the isolated UI pass.

The purple system sharing indicator and cursor glow in installed-app captures are OS overlays. They are not part of the product design.

## Equal-size comparisons

Each source frame is reduced equally to 960 × 664 pixels, preserving its full viewport and aspect ratio. No component is separately resized in these comparisons.

- `welcome-services-comparison.png`, `welcome-cloud-comparison.png`: unchanged welcome on the left, updated setup on the right.
- `services-before-after.png`, `cloud-before-after.png`: previous implementation on the left, correction on the right.

## Scope

- Setup headings: 36-point bold → 26-point semibold.
- Support copy: 18 → 14 points; option titles: 21 → 15; regular content: 13 points.
- Selection rows: 116 → 88 points; speech field: 42 → 34 points.
- Cloud product/account artwork: 116/92 → 56/48 points.
- Rail labels: 15 → 12.5 points.
- Footer: removed the separate 48-point setup button style; uses the welcome's `StudioButton` directly, including loading and disabled states.
- Existing optional login, custom configuration, skip confirmations, recovery actions, and model preservation are unchanged.

## Validation

`OnboardingBehaviorTests` is the focused scope because this patch changes native onboarding views and their shared footer. Its existing cases cover service routes, skip/recovery, shared login/editor actions, Chinese/English rendering, both appearances, permissions and finish. Extended assertions compare primary-action height and bottom inset against the welcome across seven stages and bound selection-row height relative to the welcome action.

All 13 focused methods passed on the first attempt. Total command wall time: 247.762 seconds, including build/preparation and discovery. Changed executable-line coverage: 75/79 (94.9%), not project-wide coverage. Strict SwiftLint and whitespace checks passed. Six inspected clean native fixture captures are archived as `ui-*.png`. Final timing/counts and changed-line coverage are recorded in `validation.json` and `coverage.json`. This pass does not revalidate live OAuth, microphone dictation, or model-service availability.
