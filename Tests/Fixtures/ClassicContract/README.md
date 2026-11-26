# Classic data contract fixtures

The [shared data contract](../../../docs/CLASSIC_FORK_EXECUTION_PLAN.zh-CN.md#44-共享数据契约) defines the on-disk formats shared with Classic.

| File | Contents |
| --- | --- |
| `v0.4.0-defaults.plist` | Frozen synthetic v0.4.0 defaults with plist types and representative values. |
| `defaults.plist` | Built-in OpenAI selection. |
| `defaults-cloud.plist` | Typeflux Cloud selection, including the rewrite catalog. |
| `defaults-ollama.plist` | Ollama selection. |
| `defaults-endpoint.plist` | Custom endpoint selection. |
| `history.sqlite` | One dictated record, with the database created and populated by `SQLiteHistoryStore`. |
| `personas.json`, `hotkey.json`, `vocabulary.json` | The current stored JSON formats for a custom persona, an activation hotkey, and vocabulary entries. |

Each current plist represents an independent defaults domain. All four contain the same `models.registry.v2` JSON data and differ in the single `llm.profile.reference` selection. Import each plist into its own test defaults suite. Copy the SQLite fixture to a temporary directory before opening it with a writable store.

The frozen inventory comes from `git grep -h -o -E 'forKey: "[^"]+"' v0.4.0 -- Sources | sort -u`. The tag yields 75 matches after deduplication. `deviceID` and `drawsBackground` are Key-Value Coding properties on an audio unit and a web view. The resulting 73 persisted preferences include the interpolated retry timestamp, represented by `cloudDataSync.nextAttemptAt.fixture-user`. Commented-out defaults are retained for compatibility. The XML plist tags record each stored type. JSON strings and data blobs retain the encoding used by v0.4.0.

Run `scripts/generate_classic_contract_fixtures.sh` on macOS to refresh the current artifacts after an intentional change. The script runs the fixture writer test using isolated defaults and temporary directories. It sorts JSON object keys for repeatable output and uses fixed sample identifiers and timestamps. The v0.4.0 snapshot stays frozen. Run `make test SUITE=ClassicCompatibilityContractTests` to verify the checked-in fixtures and compatibility with v0.4.0.
