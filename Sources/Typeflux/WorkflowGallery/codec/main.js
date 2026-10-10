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
  const flag = text.match(/^-([ed])(?:\s+|$)/);
  if (flag) {
    mode = flag[1] === "e" ? "encode" : "decode";
    text = text.slice(flag[0].length) || request.selection || "";
  }
  let form = false;
  if (/^--form(?:\s+|$)/.test(text)) { form = true; text = text.replace(/^--form(?:\s+|$)/, "") || request.selection || ""; }
  try {
    if (!text) throw new Error("Type text or select text first");
    console.log(codec === "base64" ? base64(text, mode) : url(text, mode, form));
  } catch (error) {
    console.log(JSON.stringify({ error: `Cannot decode: ${error.message}` }));
    process.exit(1);
  }
});

function url(text, mode, form = false) {
  const encoded = /%[0-9a-f]{2}/i.test(text) || (form && text.includes("+"));
  if (mode === "decode" || (mode === "auto" && encoded)) return decodeURIComponent(text.replace(/\+/g, " "));
  return form ? new URLSearchParams({value:text}).toString().slice(6) : encodeURIComponent(text);
}

function base64(text, mode) {
  const looksEncoded = /^[A-Za-z0-9+/_-]+={0,2}$/.test(text) && text.length % 4 === 0 && text.length >= 4;
  if (mode === "decode") {
    if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(text) || text.replace(/=+$/, "").length % 4 === 1 || (text.includes("=") && text.length % 4 !== 0)) throw new Error("Invalid Base64");
    const bytes = Buffer.from(text, "base64");
    const canonical = text.replace(/-/g,"+").replace(/_/g,"/").replace(/=+$/, "");
    if (bytes.toString("base64").replace(/=+$/, "") !== canonical) throw new Error("Invalid Base64 padding bits");
    return new TextDecoder("utf-8", {fatal:true}).decode(bytes);
  }
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
