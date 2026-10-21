# Persisted agent implementation binding

Local `AskRun.agentBinding` is Codable as `agent_binding` (`id`, `version`). Missing/null means
legacy `typeflux.default` protocol version 1; reads do not backfill it. Send,
Retry and Regenerate stamp explicit default v1 on new runs. Continuations retain
the stored binding. Placement and model routing remain independent.

Only default v1 executes. Unsupported and malformed bindings stay readable;
commands return `AGENT_IMPLEMENTATION_UNAVAILABLE` (HTTP 503) before execution
side effects. Default async admission and durable admission validate persisted
snapshots too. Unsupported durable candidates retain their job, lease, operation
and conversation state: Claim skips them and uses the existing paced idle path
when no compatible work remains. No new lifecycle state is introduced.

The cloud API is only a transport. Server public projections omit the binding,
and requests cannot select it; Swift tolerates missing cloud metadata. Local
errors use the existing localized Ask error presentation.
Older binaries cannot safely own future nondefault runs. Alternate selection
remains disabled until capability negotiation and rolling-upgrade ownership are
designed and implemented. This increment enables no external engine.


## Immutable runtime composition

The implementation registry snapshots registrations at construction and uses exact
ID/version keys. IDs start with an ASCII letter or digit and continue with ASCII
letters/digits, `.`, `_` or `-`; versions must be positive integers. Invalid setup
(duplicate keys, invalid identities, missing default, or missing Go runtime) fails
before publishing the application entry point. Descriptors contain the binding
and a set of callable operations: `send`, `result`, `inference_result`, `cancel`,
`retry`, `regenerate`, `steer`, `resume`, `observe`. These are internal interface
contracts; local Resume retains its existing compatibility behavior. The only
protocol version is `binding.version`.

`lookup` requires an exact identity. `selectDefault` checks the configured default
against all required operations. `resolvePersisted` maps a nil binding only to
legacy `typeflux.default` v1, even if an injected registry has a different default.
Explicit malformed/unknown identities and missing operations return the existing
implementation-unavailable error without invoking any runtime. Default-engine
binding guards use the canonical descriptor and still reject alternate identities,
including registered ones. History decoding, validation order and SQL eligibility
remain unchanged.

Production registers/selects only the existing default engine instance: Swift's
routed API shares its local runtime with history/catalog access in both the
conversation window and workflow editor; Go shares its configured engine with
the HTTP handler, EngineAccess and worker. Cloud AskAPIClient remains a transport.
There is no public selection field, environment switch, discovery or UI picker.

Registered does not mean compatible with an existing run or authorized to perform
a tool. This increment adds no wire capability negotiation. Missing peer capability
is not consent to an alternate implementation: alternate activation stays closed
until host state/authorization ports, per-run dispatch, protocol negotiation and
rolling-upgrade ownership are defined and tested. Fake alternate registries in tests
prove interface selection only; they do not establish production multi-engine
routing or full framework replaceability.
