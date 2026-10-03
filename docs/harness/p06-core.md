# P06 MCP schema and typed-content core

The MCP schema is an opaque JSON object. Registration, `MCPToolAdapter.definition`
and Ask serialization use the same raw dictionary, including root combinators,
`$defs`, enum/numeric constraints, additional properties and unknown metadata.
Numeric 0/1 and booleans remain distinct through Foundation bridging. Existing
limits remain: object root, 32,000 encoded bytes per schema, 500,000 bytes across
the catalog including built-ins, and 64 tools.

Before `client.callTool`, `MCPInputValidator` checks arguments against that exact
schema. Malformed JSON is never replaced with `{}`. Errors identify the instance
path/constraint, without including argument values. The offline validator supports:

- object/array/string/number/integer/boolean/null types and type unions;
- properties, required, additionalProperties, property-count bounds;
- local JSON Pointer `$ref`, `$defs`/definitions, oneOf/anyOf/allOf/not, enum/const;
- inclusive/exclusive numeric bounds, multipleOf, string-length bounds;
- array items/length/uniqueness; standard non-validating annotations.

An absent dialect uses this documented subset; an explicit dialect must be
2020-12. Unknown keywords, other dialects, remote/anchor references and unsupported
constructs (including pattern/format/conditional/unevaluated rules) fail closed
before MCP dispatch. They are preserved, not stripped or falsely claimed as
validated. Schemas/instances have depth and work limits (64 levels, 10,000 matching
operations, 256,000 argument bytes). There is no network resolver or full JSON
Schema conformance claim. Floating numeric validation uses finite IEEE doubles;
callers requiring arbitrary-precision numbers need another reviewed validator.

MCP content objects keep their complete original representation. Structured-only
results decode without a `content` array. Internal `structured_content` and
`mcp_metadata` wrappers preserve MCP result `structuredContent` and `_meta`.
Multiple images, resources and unknown types remain ordered in
`harness.outcome.content`. The optional `AskMessage.harness` and diagnostic are
additive; old caches still decode. Result status and legacy error projection are
separate: `ok` is executor completion, not verified business effect.

Bounded storage accepts 64 blocks and 1 MB total content. The client reserves
marker space and caps individual blocks at 600 KB; over-limit blocks get an
explicit `typeflux_truncated` marker with original type/size or omitted count.
Original content below these bounds survives. Model text projections truncate
visibly at 60,000 UTF-8 bytes. JPEG/PNG/GIF payloads have MIME/signature and dimension
checks. Unsupported audio/resource/binary content is never fetched or executed.

`AskTypedContent` builds both the opaque outcome and a conservative text/JPEG/error
projection. A peer without explicit trusted capability plus local rollout receives
only this projection; incomplete results are errors, never empty success. Rollout
is off by default. Capability metadata from model/user envelopes is not trusted.
P02 owns approval policy; recording an outcome preserves existing context/approval
metadata and grants no authority. No new production feature is enabled here.

The adapter PR owns conversation/journal/cache/model/UI wiring. Merge the API
compatibility PR first, then this core, then the adapter. Tests use deterministic
synthetic content and shared `p06-fixtures`, without a live MCP server or model.
