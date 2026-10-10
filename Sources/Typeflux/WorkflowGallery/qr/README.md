# QR code generator

Generate a PNG QR code from text or a selection, entirely offline.

Requires Node.js 18 or newer. No network requests or package installation at runtime.

- `qr Typeflux` — Generate a QR image from text.
- `qr` — Generate a QR image from selected text.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Creates a PNG data URL with error correction M, an eight-pixel module and a four-module quiet zone. Typeflux shows the image and provides its image actions. Oversized inputs report a QR capacity error.
