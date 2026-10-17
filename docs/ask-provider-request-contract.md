# Ask provider output contract (GUL-172)

Both Local mode and Cloud conversations using a custom model pass an OpenAI-style
inference payload through `AskCustomInference`. Ordinary requests leave the
output limit to the provider. Gemini's native translation preserves an explicit
`max_tokens` as `generationConfig.maxOutputTokens`.

| Input | Gemini request |
| --- | --- |
| Missing `max_tokens` | Omit `maxOutputTokens`; use the provider's default |
| Positive integer through `Int32.max` | The exact supplied value |
| Zero, negative, fractional, boolean, null, string, container, or integer overflow | Fail before sending |
| Local summary | 1500 |
| Explicit reasoning effort | Merge the thinking budget into the same generation config; preserve an explicit output cap if present |
| HTTP 400/422 with reasoning parameters | Retry once after stripping reasoning; preserve any explicit cap and all tool/image context |

Model-specific ceilings remain provider validation errors. The adapter does not
guess a model's maximum or silently raise a caller's limit. Gemini's output cap
includes thinking tokens, so a high thinking effort with a small cap can produce
a truncated or empty answer. The stream parser keeps reporting `MAX_TOKENS` as
truncation. See the [Gemini thinking documentation](https://ai.google.dev/gemini-api/docs/generate-content/thinking#token-limits).

OpenAI-compatible and Ollama requests omit `max_tokens` unless a run budget
sets one. Anthropic requires `max_tokens`, so its adapter retains a fallback
limit. First-turn thinking adds its budget to
the answer allowance; tool-result turns omit thinking because its blocks cannot
be replayed. A reasoning fallback never increases either provider's initial
request ceiling. This change does not introduce a Go Gemini adapter or change
Cloud catalog limits.

`AskProviderRequestContractTests` checks serialized Local and Cloud+custom
payloads at the mocked HTTP boundary, including tool-result images, Gemini
thought signatures, streaming truncation, malformed limits, and fallback.
`AskThinkingModeTests`, `ProviderModelCatalogTests`, `AskStreamTests`, and
`AskLocalModeTests` provide the adjacent regressions. The API's
`TestProviderOutputContractMatchesContextReserve` and
`TestCustomInferenceOutputContractSurvivesToolRound` pin the server's output
reserve and custom-model inference wire shape.

P06/R02 changes to `nativeBody` must rerun these fixtures. They are deterministic
request-contract checks, not validation against live providers or a signed-in
desktop. Buffered replies retain their existing handling; truncation reporting
is verified on the streaming conversation path.
