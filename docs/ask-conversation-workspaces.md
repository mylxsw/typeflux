# Ask conversation workspaces

Each Ask conversation has a local folder under
`~/.typeflux/workspaces/<owner-key>/yyyy-MM-dd/HHmmss-<conversation-id>/`.
Dates use the local time zone and Gregorian calendar. The earliest message timestamp
represents the chat start; an empty chat uses its initial update timestamp. Once
created, a workspace keeps its path across updates and time zone changes. The owner key
isolates signed-in accounts. A legacy non-UUID conversation ID uses a SHA-256
ID suffix. Legacy ID-only directories migrate on next use, using the saved chat
start time (or the directory creation time if no snapshot is available). Migration
preserves files and removes empty `inputs`, `outputs`, and `work` directories. The UI opens the exact folder in Finder.

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
Opening an older chat recovers available
message data into its workspace; missing original files cannot be recreated.

Deleting an ordinary chat leaves its workspace untouched. Temporary chats use the same
workspace root; ending one, switching accounts, or exiting the app deletes its workspace.
Converting a temporary chat to an ordinary chat retains its files.
Existing immutable artifact storage continues to serve in-chat previews;
locally generated images are also copied into `outputs/` for durable user
access. Server-provided remote image URLs remain references in
`conversation.json`; they are not downloaded automatically.
