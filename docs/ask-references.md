# Selected reply references

Select text in a completed assistant reply and choose **Ask**. The native popover
accepts an optional question; confirming only adds a reference to the draft.
The editing sheet shows the excerpt as an accent-ruled quote, a framed question
field, and **Explain this excerpt** / **Translate this excerpt** chips that fill a
visible question without sending it. ⌘↩ saves; Esc cancels.
Send is enabled once the main input or at least one reference has a question.

Draft references use a fixed-height horizontal strip, with per-item editing and
removal. The management sheet lists all entries and can locate the original reply.
Sent references retain the full selected text and associated question in collapsed
disclosures. The original reply is no longer inserted wholesale into the input.
Existing Ask surfaces, typography, accent colors and native presentation are reused
for both light and dark appearances.

`AskReference` is a value snapshot containing `id`, `messageId`, `text`, and
`question`. Optional arrays on `AskDraft`, `AskSendRequest`, and `AskMessage` keep
old persisted data compatible. Draft cache, optimistic history and send retries
carry the same values. Up to 32 references and 64,000 combined UTF-8 bytes of
reference text/questions are allowed per turn.

Deploy the companion typeflux-api references change before releasing this UI.
The API persists references in existing JSONB snapshots, validates their source
conversation, and includes them in cloud/custom inference and history summaries.
An older server does not preserve this new field.

Verification: `swift test --filter AskReferenceTests` exercises draft persistence,
wire compatibility, send/retry, limits, Unicode/Markdown selections, and native
popover confirmation/cancellation. Set `TYPEFLUX_REFERENCE_SNAPSHOTS` to an output
directory to render production views with synthetic data in both appearances.
