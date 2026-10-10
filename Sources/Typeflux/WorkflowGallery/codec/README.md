# URL / Base64

Requires Node.js 18+. Local UTF-8 encoding/decoding, without network requests.

- `url a b&c` encodes a URI component. Encoded input is automatically decoded.
- `url -e --form a b&c` uses application/x-www-form-urlencoded encoding (spaces become +).
- `url -d --form a+b%26c` decodes form text.
- `b64 hello` encodes UTF-8 text using RFC 4648 Base64.
- `b64 -d aGVsbG8=` decodes. Base64url and missing padding are accepted; invalid bytes, padding bits and invalid UTF-8 fail.
- `-e` and `-d` force a direction. Either can be used alone with selected text.

Text takes precedence over selected text. This is text Base64, separate from the launcher's positional radix-64 number representation.
