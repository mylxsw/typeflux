# Bundled emoji catalog

The native launcher reads the generated resource; it never launches Node, installs packages, or downloads data at runtime.

Regenerate on a Mac with the project's Swift toolchain:

```sh
npm ci --prefix scripts/workflow-tools
node scripts/emoji/build.cjs
node --test scripts/emoji/build.test.cjs
```

Inputs are pinned: `emoji-test-17.0.txt` from https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt, emojilib 4.0.3 and CLDR annotations 48.2.0 (the existing workflow-tool lockfile). The output records the Unicode input SHA-256 and retains the third-party notices. `pinyin.swift` generates compact spelling/initial aliases at build time using Foundation transliteration.

Only fully-qualified standard sequences are emitted. Skin-tone variants are grouped by their base, including Unicode's compact forms for multi-person handshakes, couples, dancers and wrestlers. The generator does not synthesize modifier sequences. Its tests ensure the full Unicode set survives exactly once. Runtime glyph shaping filters unavailable sequences on the user's Mac.

`search-cases.json` is the manually authored regression corpus. Each row is `[query, acceptableEmoji, ...]`; alternatives are used where multiple smiling faces are equally valid. It covers English, Chinese, shortcodes, typo tolerance, pinyin, expression suggestions, and compound emoji. Negative/no-result and cancellation cases live in the Swift test suite. Common-expression mappings live in `EmojiIntents`, separately from standard annotations; unsupported sentences are not sent to AI.
