# HTML entities

Escape HTML special characters or decode named and numeric entities.

Requires Python 3. No network requests or package installation at runtime.

- `entities -e <b>Tom & Jerry</b>` — Escape text safely for HTML.
- `entities -d &lt;b&gt;` — Decode HTML entities; selected text works too.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Default is encode. `-e` and `-d` can be used alone with selected text. Includes quote escaping and decoding of numeric Unicode entities. The result is displayed as plain text.
