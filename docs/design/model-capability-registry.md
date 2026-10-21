# Model capability registry proposal

GUL-449 evaluates a shared internal catalog for model names and capabilities.
The iOS client currently gets cloud capabilities from ChatModel, and builds private
models through ChatProvider.chatModels. Private models expose no reasoning-effort
setting; their image flag is explicitly editable. This change keeps those contracts.

## Recommendation

Maintain one versioned data file in TypefluxChat, bundled with the app for offline
use. A later server endpoint can distribute reviewed updates using ETag and a
last-known-good copy. Keep the data separate from matching code and API adapters.

Each record should contain provider namespace, exact IDs/aliases, optional anchored
family patterns, display name, context window and maximum output tokens, image
input support, reasoning-output support, supported effort values, source URLs,
verification date, and schema/data versions. Missing values mean unknown, rather
than false or an invented default.

Resolve by provider namespace and exact ID first; use narrowly scoped family
patterns only as a fallback. Do not infer capabilities from arbitrary substrings
such as “pro”, “flash”, “vision”, or a proxy's marketing alias. Quantized/local
variants and proxies can have different limits or protocols from upstream models.

Prefer explicit provider metadata, then a user's private-model image override,
then verified registry data. Preserve the distinction between generating reasoning
and accepting a reasoning-effort parameter. A registry record must never enable
effort controls until the selected provider's request adapter supports them.

## Updates and rollout

Start with a reviewed bundled file and fixture tests. Assign a catalog maintainer;
review monthly and whenever a supported provider changes its models. Proposed
updates must cite provider documentation and record the verification date.
A scheduled job may propose diffs, but must not publish guessed capabilities.

Validate schema versions, duplicate aliases, ambiguous patterns, positive token
limits, and adapter-supported effort values. Test exact matches, dated aliases,
unknown IDs, proxy renames and local variants. Reject malformed remote updates,
retain the last valid copy, and keep the bundled catalog as fallback.

This issue delivers the UI fixes and this evaluation. Registry data population,
the update endpoint and scheduled maintenance require a separate implementation;
no periodic updater or unverified model capability data is introduced here.
