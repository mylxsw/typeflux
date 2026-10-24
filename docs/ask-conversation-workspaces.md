# Ask conversation workspaces

Each Ask conversation has a local folder under
`~/.typeflux/workspaces/<owner-key>/yyyy-MM-dd/HHmmss-<conversation-id>/`.
Dates use the local time zone and Gregorian calendar. The earliest message timestamp
represents the chat start; an empty chat uses its initial update timestamp. Once
created, a workspace keeps its path across updates and time zone changes. The owner key
isolates signed-in accounts. A legacy non-UUID conversation ID uses a SHA-256
ID suffix. Legacy ID-only directories migrate on next use, using the saved chat
start time (or the directory creation time if no snapshot is available). Migration
preserves files and removes empty `inputs`, `outputs`, and `work` directories. The history menu's
"Show files" opens the conversation's Files tab in the Chat side panel; the Files tab can
reveal the exact folder in Finder.

The folder contains `inputs/` for copies of submitted files and screenshots,
`work/` for projects, `outputs/` for generated image files, and `.typeflux/`
for `conversation.json`, `files.json`, and temporary command files. These
subdirectories are created only when needed: saving metadata creates `.typeflux/`,
submitting file bytes creates `inputs/`, generating images creates `outputs/`,
and file tools or commands create `work/` when writing projects there. Command
execution creates `.typeflux/tmp/` before setting `TMPDIR`. File tools
resolve relative paths from the conversation root. The host command starts in
the root with `TMPDIR` pointed inside it and `TYPEFLUX_WORKSPACE` set. Absolute paths remain
possible when the user explicitly asks to work elsewhere; `run_command` is
still a host command with the user's normal account access, not a sandbox.

User file and image originals are copied before the request is sent. Pasted
images and legacy attachments without an original path are stored in their
processed form, identified as such in `files.json`. Folder attachments remain
references to the explicitly attached external folder and are identified in
the manifest. Cloud conversation messages are mirrored locally. Typeflux does
not sync workspace files.

Each round (a question and the run that answers it) snapshots `outputs/` and `work/`
when it starts and again when its run ends; a run paused for a decision or for credits
keeps its first snapshot. Files that are new or whose content changed are recorded in
`files.json` with the round's last answer as `messageId`, `change` (`added` or
`modified`), and the counts of `files` tool `writes` and `edits` for that path. Deleted
files and files that were only touched are not recorded. Older records have no `change`
and are not treated as changes. The answer lists these files at its end; reloading the
history reads them back from `files.json`.

Opening an older chat recovers available
message data into its workspace; missing original files cannot be recreated.

Deleting an ordinary chat leaves its workspace untouched. Temporary chats use the same
workspace root; ending one, switching accounts, or exiting the app deletes its workspace.
Converting a temporary chat to an ordinary chat retains its files.
Existing immutable artifact storage continues to serve previews, which open in the
side panel;
locally generated images are also copied into `outputs/` for durable user
access. Server-provided remote image URLs remain references in
`conversation.json`; they are not downloaded automatically.
