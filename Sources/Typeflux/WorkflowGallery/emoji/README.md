# Emoji search

Typeflux now includes native offline emoji search (`emoji` / `表情`), with live results, typo tolerance and common expression suggestions. New users can use the built-in keyword directly. This legacy workflow remains available for existing installations and custom scripts; its keyword is preserved on upgrade.

Find emoji by English or Chinese keywords and copy a result.

Requires Node.js 18 or newer. No network requests or package installation at runtime.

- `emoji smile` — Search by English keywords or short names.
- `emoji 笑` — Search Simplified or Traditional Chinese keywords.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Complete emojilib English keyword data plus Unicode CLDR Simplified/Traditional Chinese annotations are bundled in emoji.json. Matches all query words; up to 80 copyable results. Empty query lists emoji. Runs a local search on Return and never uploads text.
