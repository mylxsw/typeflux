# Local data directory

Typeflux stores its own files below `~/.typeflux/`:

| Directory | Contents |
| --- | --- |
| `data/` | Skills, workflows, local models, audio, recordings, SQLite databases, indexes, and other durable app data |
| `workspaces/` | Conversation workspaces and their saved inputs and outputs |
| `cache/` | Launcher icons, workflow drafts and caches, and short-lived code workspaces |

On the first launch after upgrading, Typeflux moves existing files from
`~/Library/Application Support/Typeflux`, `~/Documents/Typeflux/Workspaces`,
and `~/Library/Caches/Typeflux` into these locations. It leaves symbolic links
at the old paths so existing absolute paths continue to work. The move happens
before Typeflux opens its databases. If both an old directory and its new
destination already contain data, Typeflux keeps using the old directory and
logs the conflict instead of overwriting either copy. Resolve the conflict
with Typeflux closed, then relaunch.

macOS still manages app preferences through UserDefaults and secrets through
Keychain. These cannot safely be treated as ordinary files inside `.typeflux`.
