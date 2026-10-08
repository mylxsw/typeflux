# Workflow authoring in Chat

Chat can load the built-in `typeflux-workflow-author` skill when a user asks for a reusable tool. One-off transformations remain ordinary Chat requests. The model selects the skill using its description; there is no keyword classifier or separate model request.

## Data flow

`AskLocalTools` exposes the existing five authoring tools plus `workflow_list`, `workflow_start`, and `workflow_save`. They operate on an `AskWorkflowAuthoringSession` implementing the editor's `AskWorkflowAuthoringHost` protocol. Proposals use the existing manifest, path, file-size, keyword, and risk validation.

Each account/conversation has one draft. `AskWorkflowAuthoringStore` persists the draft and its original save baseline under Application Support, outside installed workflow packages. Account changes cancel and release active sessions; deleting a conversation removes its record. Drafts do not sync to other devices. Restoring a conversation restores the draft, not an old run result.

The transcript card and native SwiftUI preview observe that same session. Advanced editing uses the existing syntax-aware `AskWorkflowCodeView` against the same draft, without saving it first. Existing standalone workflow editor behavior remains available for installed workflows.

## Preview and execution

The right panel shares the workspace's existing inline/drawer layout and is mutually exclusive with usage details. It provides query text, selection text, manifest keyword presets, validation, run/cancel, undo, save, and discard. It does not interpret generated HTML or introduce a form/graph schema.

Every test captures a revision, manifest, input batch, and run ID, then materializes an isolated staging copy and executes through `AskWorkflowTester` / `AskWorkflowRunner`. Results are published only while both the revision and run ID still match. Editing or cancelling invalidates the run. The snapshot directory remains alive for relative images until the result is replaced or the session is released. Runtime-created files are not installed when saving the source draft.

`AskWorkflowLauncherPreview` decodes the result using the launcher's existing text, Markdown, items, image, auto, and no-display output types. Post-run actions are listed but never executed in the Chat preview. Scripts still have real local effects: staging is not an OS sandbox. AI test calls go through Chat's existing execution journal and approval boundary; the binding includes account, conversation, draft revision, and saved baseline hash, and cannot be reused. The direct tool dispatcher rejects test execution. Clicking Run in the panel requests approval for the current revision.

Tests are nonstreaming in this first version. The tester uses the Typeflux source-application context; it does not impersonate another foreground application.

## Saving

`workflow_save` reveals the panel and asks the user to press Save. It does not install by itself. The button uses the existing store install/save APIs. Existing workflows require the original hash to match, including when staging resources for a test. A conflict leaves installed files untouched. The user can discard the conversation draft and reopen the installed workflow. New installations are trusted as in the existing editor; editing an untrusted imported workflow does not silently grant trust.

## Verification

`AskWorkflowAuthoringTests` covers real script execution, owner/conversation isolation and restart recovery, proposal/advanced-edit undo, approval freshness, the Chat run loop, explicit publication, external conflicts and resources, deletion, timeout, required input, cancellation, action previews, and image lifetime. `AskWorkflowAuthoringVisualTests` checks drawer geometry and can render wide light/dark and narrow workspaces with `TYPEFLUX_ASK_SNAPSHOTS` set. Existing workflow/editor/Chat tests provide regression coverage.
