# Markdown / HTML / XML tools

Convert Markdown and HTML; prettify or minify HTML and XML.

Requires Node.js 20 or newer. No network requests or package installation at runtime.

- `md2html # Hello` — Convert Markdown to HTML.
- `html2md <h1>Hello</h1>` — Convert HTML to Markdown.
- `htmlfmt min <div> hello </div>` — Minify HTML; omit min to prettify.
- `xmlfmt min <root><a>1</a></root>` — Minify XML; omit min to prettify.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Keywords: md2html, html2md, htmlfmt, xmlfmt. Formatting keywords accept `pretty` or `min` followed by text, or apply to the selection. Generated HTML is shown as text, never executed. Markdown/HTML conversion is lossy for unsupported HTML structures. HTML minification keeps JS/CSS unchanged and uses conservative whitespace collapse. XML DTD/entities are rejected; mixed-content whitespace is preserved.
