#!/usr/bin/env node
// url / b64: encodes or decodes text. Both keywords run this script; the keyword's
// preset option `codec` says which one, and arrives as the first argument.
// Text that is already encoded is decoded; `-e` or `-d` in front decides instead.
const [codec = "url", query = ""] = process.argv.slice(2);
let input = "";
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", () => {
  const request = JSON.parse(input.split("\n")[0] || "{}");
  let text = query || request.selection || "";
  let mode = "auto";
  const flag = text.match(/^-([ed])\s+/);
  if (flag) {
    mode = flag[1] === "e" ? "encode" : "decode";
    text = text.slice(flag[0].length);
  }
  try {
    console.log(codec === "base64" ? base64(text, mode) : url(text, mode));
  } catch (error) {
    console.log(JSON.stringify({ error: `Cannot decode: ${error.message}` }));
    process.exit(1);
  }
});

function url(text, mode) {
  const encoded = /%[0-9a-f]{2}/i.test(text);
  if (mode === "decode" || (mode === "auto" && encoded)) return decodeURIComponent(text.replace(/\+/g, " "));
  return encodeURIComponent(text);
}

function base64(text, mode) {
  const looksEncoded = /^[A-Za-z0-9+/_-]+={0,2}$/.test(text) && text.length % 4 === 0 && text.length >= 4;
  if (mode === "decode") return new TextDecoder("utf-8").decode(Buffer.from(text, "base64"));
  if (mode === "auto" && looksEncoded) {
    // Text that only looks like Base64 ("test") is encoded when it does not decode to UTF-8.
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(Buffer.from(text, "base64"));
    } catch {
      // Not Base64 after all.
    }
  }
  return Buffer.from(text, "utf8").toString("base64");
}
