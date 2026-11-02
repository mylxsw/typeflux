# Ask prompt policy

The production prompt is generated from
`typeflux-api/internal/ask/policy/prompt-policy.json`. The detailed design and
operator evaluation commands live in `typeflux-api/docs/ask-prompt-policy.md`.
The generated Swift file is committed so a client checkout builds independently.

From the API checkout, generate or verify both hosts:

```sh
python3 scripts/generate_ask_prompt_policy.py --swift-root ../typeflux
python3 scripts/generate_ask_prompt_policy.py --swift-root ../typeflux --check
```

`AskPromptSections` interprets generated tool capability selectors. The universal
prefix contains the current-request and trust rules. File writes and application
changes receive effect verification guidance. Read-only browser observations do
not receive an instruction to verify every read by reading again. Specialized
task acceptance procedures belong in skills.

The modular builder places labeled memory, summaries, saved plans and request anchors in the
provider's user-role context, ahead of retained history. Current user messages
remain verbatim. `AskPromptContext` identifies the generated historical envelopes
for compaction; `AskMemory.removingInjection` handles both old system-role and new
user-role memory. It preserves independent memory removal and excludes historical
context when locating the latest real user question. No stored raw conversation
messages are rewritten.

The canonical policy digest is available as `AskPromptPolicyText.digest`.
`LegacyV1` remains frozen for compatibility checks. Pending requests keep their
original payload and binding; a new policy applies to newly composed requests.

Targeted validation covers prompt selection, context roles, memory removal,
compaction and the affected engine callers. Live evaluations use real model
responses with canned device results; they do not demonstrate native desktop
behavior. The screenshot capability filter and execution guard remain separate
runtime protections.

Historical user-role envelopes use standard provider participant names (`typeflux_memory`, `typeflux_summary`, `typeflux_requests`, and locally `typeflux_plan`). Privacy and compaction checks require both the name and the envelope marker. A user asking about literal `<user_memory>` text cannot thereby turn their question into removable memory. Legacy system-role envelopes remain recognized. Native provider adapters project these messages into their supported role/content format.
