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
