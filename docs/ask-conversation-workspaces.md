# Ask conversation workspaces

Each Ask conversation has a local folder under
`~/Documents/Typeflux/Workspaces/<owner-key>/<conversation-id>/`. The owner key
isolates signed-in accounts. A legacy non-UUID conversation ID uses a SHA-256
directory name. The UI opens the exact folder in Finder.

The folder contains `inputs/` for copies of submitted files and screenshots,
`work/` for projects, `outputs/` for generated image files, and `.typeflux/`
for `conversation.json`, `files.json`, and temporary command files. File tools
resolve relative paths from the conversation root. The host command starts in
the root with `TMPDIR` pointed inside it and `TYPEFLUX_WORKSPACE` set. Absolute paths remain
possible when the user explicitly asks to work elsewhere; `run_command` is
still a host command with the user's normal account access, not a sandbox.

User file and image originals are copied before the request is sent. Pasted
images and legacy attachments without an original path are stored in their
processed form, identified as such in `files.json`. Folder attachments remain
references to the explicitly attached external folder and are identified in
the manifest. Cloud conversation messages are mirrored locally. Typeflux does
not sync workspace files; macOS may sync Documents when iCloud is enabled.
Opening an older chat recovers available
message data into its workspace; missing original files cannot be recreated.

Deleting any chat leaves its workspace untouched. Temporary chats use the same
durable workspace root; ending one deletes its chat history but keeps its files.
Existing immutable artifact storage continues to serve in-chat previews;
locally generated images are also copied into `outputs/` for durable user
access. Server-provided remote image URLs remain references in
`conversation.json`; they are not downloaded automatically.
