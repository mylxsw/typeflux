# URL / Base64

- `url a b&c` — URL-encodes the text; `url a%20b` decodes it.
- `b64 hello` — Base64-encodes the text; `b64 aGVsbG8=` decodes it.
- Put `-e` or `-d` in front to choose: `b64 -d aGVsbG8=`.

Both keywords run `main.js`; each carries a preset option `codec` that the script reads as its first argument.
Needs Node (`brew install node`).
