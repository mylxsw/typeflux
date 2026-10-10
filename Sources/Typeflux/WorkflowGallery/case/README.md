# Case converter

Convert text into 14 naming styles; choose a result to copy.

Requires Node.js 18 or newer. No network requests or package installation at runtime.

- `case helloWorld` — List all 14 conversions.
- `case snakecase Hello world` — Use a specific style; selected text works too.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Supported modes: lowercase, uppercase, camelcase, capitalcase, constantcase, dotcase, headercase, nocase, paramcase, pascalcase, pathcase, sentencecase, snakecase, mockingcase. Lowercase/uppercase keep punctuation; naming modes split punctuation and camelCase/acronym boundaries. Mocking case alternates letters deterministically.
