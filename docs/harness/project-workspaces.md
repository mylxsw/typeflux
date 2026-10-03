# Project workspaces (GUL-176 / D01)

This implementation adds local project reading, versioned staging, review, task-only undo and patch export. `AskLocalTools(projectModeEnabled:)` is an independent, **default-false** rollout gate. Production composition does not set it. It does not enable analysis `run_code`, web fetch, automation writes, approval reuse, or new harness wire capabilities.

## Storage and ownership

`AskProjectWorkspace` uses a controlled change manifest for **both Git repositories and ordinary folders**. It reads the actual working copy, including pre-existing dirty text. Writes update the private manifest, never the source root, Git index, HEAD, existing worktrees or untracked files. This first backend does not create Git worktrees or apply patches automatically. The explicit user export produces a conventional unified patch that can be reviewed/applied independently. Whole-file hunks deliberately prefer correctness to a minimal diff; they include missing-final-newline markers and Git-quoted UTF-8 paths.

The host supplies `AskProjectScope(ownerId, conversationId, runId)` from the authenticated execution loop through `bindExecution`. Model arguments cannot choose these identities. `open` selects one exact root from the current Settings or conversation folder grants, then requires P02 single-use approval of that root and the resulting workspace ID. Existing `files` definitions, arguments and approvals remain compatible. A project call through the unapproved `execute` entry point is rejected.

Local manifests live under Application Support/Typeflux/AskProjects in private directories. Each workspace is locked across store instances/processes and updated through an exclusive temporary file plus descriptor-relative atomic rename. No automatic cleanup deletes user worktrees or source files. `revert` publishes an empty manifest for this workspace only; it requires the current workspace version and is safe even when the source has changed. Disabling rollout retains manifests and the explicit user export path. Revoking folder access also denies export until the user authorizes the root again.

## Frozen WorkspaceRef integration seam

The existing P00 `AskWorkspaceRef` wire DTO is unchanged:

| Field | D01 meaning |
| --- | --- |
| `id` | Stable opaque local registry key derived from owner, conversation, run, authorized root and root filesystem identity (device, inode and birth time). Reopening the same task/root preserves it. A different owner, conversation, run or root identity does not inherit it. |
| `ownerId`, `conversationId`, `runId` | Host-supplied ownership; checked on every operation, including reopen and export. |
| `version` | Manifest revision (`initial`, then a random revision after staging/undo). Export and undo reject stale revisions. |
| `cleanup` | `user_managed`. No automatic root/worktree deletion and no implicit process cleanup authorization. |

`reference(root:scope:authorizedRoots:)` resolves the ID and root identity for approval without creating storage. `open` persists or reopens the registry record. `withValidatedSnapshot(ref:scope:authorizedRoots:body:)` is the synchronous host-only seam for D02/D03: it validates the complete reference and current authorization, locks the workspace, verifies all captured source versions, then supplies the change manifest and read-only descriptor-based source access. It revalidates captured sources after the callback. **The source root alone is not the staged working copy.** D02 must materialize the manifest over a controlled execution copy and establish its own containment/network/process policy before launching anything. D03 must use its own artifact IDs, retention and preview policy. Neither may treat a reference, root path or this callback as approval to execute programs. Do not pass source descriptors to child processes or retain them beyond the callback.

`AskProjectWorkspaceTests` and `AskProjectToolTests` are executable fixtures for reopen, ownership, revision mismatch, source conflicts, revocation, descriptor substitution, patch application and disabled rollout. The implementation commit in the PR is the fixed interface version; consumers must pin that commit or a subsequent reviewed merge, not follow an active branch.

## Version and file safety

Source files are opened `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` by walking every directory component with `openat`. Only OS-owned `/tmp`, `/var`, `/etc` aliases are normalized. Source roots and children cannot be symlinks; hardlinks, nonregular files, traversal, control characters and `.git` metadata are rejected. File reads compare inode/device, size, timestamps and link/type metadata before/after reading, then re-walk the path to detect replacement. The file version also includes SHA-256 of the content. Edit/write require the returned version; source conflicts block further staged reads, edits, review and export until the task's changes are reverted and the file is reread.

All project execution is synchronous on the existing main-actor authorization boundary, without suspension between final grant validation and bounded file operations. Source changes after the final validation cannot be locked out of arbitrary external editors; they still cannot lose data because the source is never written. Subsequent operations detect them. The threat model covers model-controlled paths and concurrent editors, not a malicious unrestricted program running as the same macOS user that can replace Typeflux or its private storage.

## Limits and presentation

- UTF-8 text only. NUL anywhere in the file or invalid UTF-8 produces an explicit encoding/binary error.
- Reads: at most 16 MiB per file, bounded in memory; line pagination reports total lines and `nextOffset`. `Int.min`/`Int.max` offsets and limits cannot overflow. A line longer than the 24,000-byte preview is explicitly marked `truncatedLine`; this is not lossless byte streaming.
- Staging: at most 1,000,000 bytes per original/updated file, 100 files and 4 MiB combined original/updated bytes. No binary edits, deletes, mode changes or automatic merges. Distinct case/Unicode-normalization aliases cannot be staged as separate files. Lists include staged directories and explicitly report truncation above 500 entries.
- Review: a 24,000-byte diff preview plus full patch hash. The activity card exports the full patch through a user-chosen save destination. After the save dialog, it rechecks owner, grants, workspace revision, source versions and patch hash; export failures remain visible in the card.
- Rollout rollback: omit the project definition and reject project dispatch, keep ordinary `files` and retained patch export. New provider/wire capabilities stay unchanged.

Remote push/PR creation, worktree management, complex rebase, project terminal execution, artifact serving and previews are outside this backend. D02/D03/D04 own the subsequent runtime and end-to-end integration. This PR does not claim real-model, remote-MCP or production desktop acceptance.
