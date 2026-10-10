# String obfuscator

Mask text, optionally preserving its beginning or end.

Requires Node.js 18 or newer. No network requests or package installation at runtime.

- `obfuscate --keep-start 3 --keep-end 4 13812345678` — Mask the middle of a phone number.
- `obfuscate --percent 50 secret` — Mask a percentage; this is not encryption.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Options: --keep-start N, --keep-end N, --percent 0..100, --mask X. Default masks everything with *. Masking proceeds from the beginning of the remaining middle span and rounds up. Counts Unicode code points. Use `-- ` before literal text beginning with --. Redaction is not encryption and this tool does not establish that a document is safe to publish.
