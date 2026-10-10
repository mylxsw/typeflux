# YAML / TOML / JSON / XML

Convert between all four formats locally.

Requires Node.js 18 or newer. No network requests or package installation at runtime.

- `data yaml json name: Typeflux` — Choose source and target formats.
- `data json toml` — Convert selected JSON into TOML.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Use `data SOURCE TARGET [text]` (or `data SOURCE to TARGET`). All 12 directed format pairs work. XML uses a single root (or a generated `<root>` wrapper); attributes use `@_` and text uses `#text`. XML scalars remain strings. TOML dates become ISO strings. TOML requires an object and cannot represent null. YAML custom tags/complex keys and XML DTD/entities are not supported. Cross-format conversion preserves common data, not comments, XML mixed-content order, or type features without equivalents.
