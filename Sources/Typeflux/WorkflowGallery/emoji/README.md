# Emoji search

Find emoji by English or Chinese keywords and copy a result.

Requires Node.js 18 or newer. No network requests or package installation at runtime.

- `emoji smile` — Search by English keywords or short names.
- `emoji 笑` — Search Simplified or Traditional Chinese keywords.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Complete emojilib English keyword data plus Unicode CLDR Simplified/Traditional Chinese annotations are bundled in emoji.json. Matches all query words; up to 80 copyable results. Empty query lists emoji. Runs a local search on Return and never uploads text.
