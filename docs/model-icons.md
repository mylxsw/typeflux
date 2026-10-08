# Model icons

Both clients resolve icons through `TypefluxChat.ModelIconResolver`. The bundled
catalog includes every Models entry in Lobe Icons at the recorded revision,
plus provider-classified logos needed for common model families and fallbacks.
Artwork and its MIT license ship inside the shared Swift package; no CDN or
runtime network request is needed. PNGs are decoded and cached by each client.
Colored artwork is preferred; Kimi uses its monochrome variant because the
upstream colored logo has a fixed white mark that disappears on light surfaces.
The macOS release and development scripts copy both Swift package resource
bundles into `Contents/Resources`; Xcode embeds the iOS bundle automatically.

Resolution order:

1. `auto` and `default` routing aliases use the generic symbol.
2. Exact full model ID overrides in `rules.json`, then the unqualified model ID
   without a colon-delimited routing tag.
3. Family in the final slash-separated model ID component.
4. Family in the display name, then known owner namespaces, nearest first.
5. Known provider logo; otherwise the desktop's existing provider tile or the
   generic model symbol when no provider is available.

Matches require token boundaries, with attached version digits allowed. The
first family in a compound name wins; at the same position the longest match
wins. This preserves DeepSeek branding for `DeepSeek-R1-Distill-Qwen-32B`, while
`command-a` and `glm-4.6v` take precedence over `command` and `glm`. Opaque custom
deployment IDs can use a recognizable display name or fall back to their provider.
No matching rule changes the model ID, API protocol, or request routing.

`Resources/ModelIcons/rules.json` contains curated regex aliases and exact
provider IDs. Every catalog entry also matches its canonical key automatically.
New versions of a known family need no update. New families or renamed aliases
require an app update; unknown models remain selectable with a fallback icon.

To update assets, clone `https://github.com/lobehub/lobe-icons`, check out the
desired commit, and run from this repository:

```sh
python3 scripts/sync_model_icons.py --source /path/to/lobe-icons --revision <commit>
python3 scripts/sync_model_icons.py --source /path/to/lobe-icons --revision <commit> --check
swift test --package-path Packages/TypefluxChat --enable-code-coverage
```

The importer requires a clean checkout, validates PNG signatures before writing,
reports changes, removes retired artwork, and records SHA-256 hashes and the
upstream commit in `catalog.json`. Review category changes and aliases together;
update the pinned revision and inventory-count assertions when intentionally
upgrading. Tests verify every asset, both themes, family conflicts, unknown names,
provider fallback, and resource decoding on both clients.
