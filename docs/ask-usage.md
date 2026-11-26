# Ask usage

The usage panel adds controls outside the existing composer. The composer, voice
input, attachments, model picker and keyboard behavior are unchanged.

Conversation content and usage have independent revisions. Usage must be merged
without replacing a newer content snapshot. The local cache preserves the newer
usage version when a delayed response contains older metering.

Cloud amounts come from the API's existing billing recorder in microcredits.
Own API reports include tokens only and never authorize Cloud billing. A pending
or missing value is not zero. Totals include all calls in a run, including summaries
and tool decisions; each assistant message links to its run's aggregate.

Local conversations persist provider-reported tokens and invocation details next
to their history, including summaries, failures and cancelled calls. The panel
shows tokens instead of credits and reads local records without a Cloud session.
Duplicate receipts are counted once; late usage can update a recorded invocation
without changing a completed or replacement run. Missing or partial reports stay
unknown or a lower bound. Older conversations still load, with a historical gap
when metering starts; tokens from calls made before metering cannot be recovered.

Context estimates describe saved request content, not the unsent draft. Switching models hides the previous request’s context until the selected model has its own request. Earlier messages replaced by a summary are excluded from the input
budget, but remain in history and cumulative usage.

### Image input estimates

The API retains the prepared request estimate so subsequent answers and tool results cannot change it. For a private model, the API returns the image count and text estimate so the device can use its local model registry.

Before a model reports usage, the panel assigns each image a token estimate for
the model family. The presets assume a typical 1600 × 900 screenshot at default
detail. The preview estimates text and tool definitions separately from images. For example, Gemini 3/4 uses 1,120 per image. GPT-4o uses six tiles at
170 plus 85 base tokens, while GPT-4o mini uses six at 5,667 plus 2,833.
Unrecognized models use a fixed estimate of 2,000 tokens per image. Individual images
can cost more or less. The planner continues to use its own admission budget.

The ordered rules in the API's `internal/ask/policy/image-token-estimates.json`
are also packaged in the Mac app's `Sources/Typeflux/Resources/image-token-estimates.json`.
Keep the two files identical. Estimates use the first recognized model identifier
or catalog name, accepting provider paths, case, separators and version suffixes.

Provider references: [Gemini](https://ai.google.dev/gemini-api/docs/media-resolution),
[OpenAI](https://developers.openai.com/api/docs/guides/images-vision),
[Claude](https://platform.claude.com/docs/en/build-with-claude/vision) and
[Qwen](https://www.alibabacloud.com/help/en/model-studio/vision).
