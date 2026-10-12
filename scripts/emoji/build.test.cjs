const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const catalog = require('../../Sources/Typeflux/Resources/Emoji/emoji-catalog.json');
const source = fs.readFileSync(path.join(__dirname, 'emoji-test-17.0.txt'), 'utf8');
test('catalog preserves every fully-qualified Unicode sequence exactly once', () => {
  const expected = source.split('\n').flatMap(line => {
    const match = line.match(/; fully-qualified\s*# (\S+) E/);
    return match ? [match[1]] : [];
  });
  const actual = catalog.entries.flatMap(entry => [entry.sequence, ...entry.variants.map(v => v.sequence)]);
  assert.equal(new Set(actual).size, actual.length);
  assert.deepEqual(new Set(actual), new Set(expected));
  assert.equal(catalog.sha256, crypto.createHash('sha256').update(source).digest('hex'));
});
test('skin tones are variants, including multi-person compact base forms', () => {
  assert.equal(catalog.entries.some(e => /[\u{1f3fb}-\u{1f3ff}]/u.test(e.sequence)), false);
  assert(catalog.entries.find(e => e.sequence === '🤝').variants.some(v => v.sequence === '🫱🏻‍🫲🏽'));
  assert(catalog.entries.find(e => e.sequence === '🙏').variants.some(v => v.sequence === '🙏🏽'));
});
test('stable IDs and localized names accompany every entry', () => {
  for (const entry of catalog.entries) {
    assert.equal(entry.id, Array.from(entry.sequence).map(c => c.codePointAt(0).toString(16)).join('-'));
    for (const language of ['en', 'zh', 'zh-Hant']) assert(entry.names[language]);
    assert(entry.keywords.length && entry.group && entry.version);
  }
});

test('pinyin aliases are generated for Chinese keywords', () => {
  assert(catalog.entries.find(e => e.sequence === '😄').pinyin.includes('kaixin'));
  assert(catalog.entries.find(e => e.sequence === '😄').pinyin.includes('kx'));
  assert(catalog.entries.find(e => e.sequence === '😊').pinyin.includes('weixiao'));
});
