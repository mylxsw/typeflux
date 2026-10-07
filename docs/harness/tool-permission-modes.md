# Tool permission modes (GUL-249)

The composer offers Strict, Standard (default), and YOLO. `/mode strict`,
`/mode standard`, and `/mode yolo` change the current conversation locally,
including while a call waits for approval. `/mode` opens choices; malformed
arguments stay local and show usage. Commands never enter chat history or the
send queue. A launcher draft transfers its mode when sent or moved into chat.

- Strict asks for every tool call, including reads, skills, and engine tools.
- Standard automatically grants trusted built-in read/no-effect actions inside
  their existing access boundaries. Writes, code, paid generation, and unknown
  MCP tools ask. Screen capture keeps the explicit submitted screenshot scope;
  changing the checkbox later or reloading an old image cannot grant it.
- YOLO automatically grants every enabled tool. OS permission, file roots,
  sandbox availability, tool rollout gates, budgets, and cancellation still apply.

Modes live only in the conversation model's memory. New conversations and a
new application session start in Standard. Stop resets the conversation to
Standard; account reset and deletion remove authority. Changing mode revokes
existing grants before reconsidering a pending call. A mode change cannot undo
an operation already dispatched. The model, tools, and decoded server snapshots
cannot change mode.

Each allowed call still receives a new exact-argument/target single-use grant.
The execution journal, live-call comparison, dispatch revalidation, and revocation
checks are retained. There is no tool-name wildcard grant or imported receipt.

## Engine tools and rollout

New chat requests opt into `client_tool_approval`. Both AskLocalEngine and the
API pause their own tools (including search and update_plan) in `waiting_tool`.
The device classifies those calls using pinned engine definitions and sends an
explicit `approve_execution` decision through the existing tool-result endpoint.
The engine executes only the stored call and produces the actual result; it
never accepts the decision's content as a tool result. Each following call waits
for its own decision. Legacy clients without the opt-in keep their existing flow.

Cloud authorization receipts are revalidated immediately before sending; a
restart or revoked in-memory grant cannot replay a saved authorization. The
server atomically advances the waiting state before dispatch. Durable workers
wait without starting or charging the operation, then resume through a
sequence-checked job transition. Actual execution retains the durable intent
and budget checks. Public snapshots omit the consumed server authorization ID.

Deploy the companion API change first. The client checks the authenticated
`GET /ask/conversations/tool-approval` capability (version 1) before sending an
opted-in message, retry, or regeneration; an unsupported server receives no new message.
No database migration or persisted permission preference is required. Pre-upgrade
running jobs retain their original contract; stop and retry them to activate the
new engine approval boundary. Retry upgrades legacy runs as well.

## Validation

Tests cover the mode matrix, command parsing, busy-composer Return handling,
pending-call continuation, downgrade before dispatch, account reset, new chats,
cloud capability discovery, local engine allow/deny/replay, and cloud engine
allow/deny/replay including PostgreSQL durable jobs. Existing target, expiry,
screenshot-consent, sandbox, and journal suites remain authoritative.
