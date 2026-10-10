# JWT parser

Read the header, payload, timestamps and expiry without uploading tokens.

Requires Node.js 18 or newer. No network requests or package installation at runtime.

- `jwt eyJhbGciOiJub25lIn0.eyJzdWIiOiIxMjMifQ.` — Decode a token; signature is not verified.
- `jwt` — Parse the selected token.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Supports three-part JWTs with Base64url header/payload objects, including an empty signature. Encrypted five-part JWE is rejected. Shows iat/nbf/exp as UTC and expiry at run time. This is a decoder, not authentication: signatures, issuer and audience are never verified.
