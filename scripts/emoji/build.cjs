// Regenerate after `npm ci --prefix scripts/workflow-tools`.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const dependencies = path.join(root, 'scripts/workflow-tools/node_modules');
const tags = require(path.join(dependencies, 'emojilib'));
const annotations = Object.fromEntries(['en', 'zh', 'zh-Hant'].map(locale => [locale,
  require(path.join(dependencies, 'cldr-annotations-full/annotations', locale, 'annotations.json')).annotations.annotations]));
const source = fs.readFileSync(path.join(__dirname, 'emoji-test-17.0.txt'), 'utf8');
const bare = s => s.replace(/[\u{1f3fb}-\u{1f3ff}\ufe0f]/gu, '');
const id = s => Array.from(s).map(c => c.codePointAt(0).toString(16)).join('-');
let group = '';
const all = [];
for (const line of source.split('\n')) {
  if (line.startsWith('# group: ')) group = line.slice(9);
  const m = line.match(/^([A-F0-9 ]+)\s*; fully-qualified\s*# (\S+) E([\d.]+) (.+)$/);
  if (!m) continue;
  const sequence = m[2];
  const names = {}, keywords = new Set(tags[sequence] || []);
  for (const [locale, entries] of Object.entries(annotations)) {
    const a = entries[sequence] || entries[sequence.replace(/\ufe0f/g, '')];
    names[locale] = a?.tts?.[0] || m[4];
    for (const tag of [...(a?.tts || []), ...(a?.default || [])]) keywords.add(tag);
  }
  keywords.add(m[4]);
  all.push({id: id(sequence), sequence, names, keywords: [...keywords], group, version: m[3], variants: []});
}
const bases = new Map(all.filter(e => !/[\u{1f3fb}-\u{1f3ff}]/u.test(e.sequence)).map(e => [bare(e.sequence), e]));
// Unicode uses compact unmodified forms for these multi-person sequences.
const variantBases = {'🫱‍🫲':'🤝', '🧑‍🐰‍🧑':'👯', '👨‍🐰‍👨':'👯‍♂', '👩‍🐰‍👩':'👯‍♀',
  '🧑‍🫯‍🧑':'🤼', '👨‍🫯‍👨':'🤼‍♂', '👩‍🫯‍👩':'🤼‍♀',
  '👩‍🤝‍👩':'👭', '👩‍🤝‍👨':'👫', '👨‍🤝‍👨':'👬', '🧑‍❤‍💋‍🧑':'💏', '🧑‍❤‍🧑':'💑'};
const entries = [];
for (const e of all) {
  const key = bare(e.sequence);
  const base = bases.get(variantBases[key] || key);
  if (base && base !== e) base.variants.push({sequence: e.sequence, names: e.names});
  else entries.push(e);
}
const {execFileSync} = require('node:child_process');
const han = word => Array.from(word).length <= 6 && /\p{Script=Han}/u.test(word);
const chinese = [...new Set(entries.flatMap(entry => entry.keywords.filter(han)))];
const pinyin = JSON.parse(execFileSync('swift', [path.join(__dirname, 'pinyin.swift')],
  {input: JSON.stringify(chinese), maxBuffer: 8 * 1024 * 1024}).toString());
for (const entry of entries) entry.pinyin = [...new Set(entry.keywords.flatMap(word => pinyin[word] || []))];
const output = path.join(root, 'Sources/Typeflux/Resources/Emoji');
fs.mkdirSync(output, {recursive: true});
fs.writeFileSync(path.join(output, 'emoji-catalog.json'), JSON.stringify({schema: 1, unicode: '17.0',
  cldr: '48.2.0', sha256: crypto.createHash('sha256').update(source).digest('hex'), entries})+'\n');
fs.writeFileSync(path.join(output, 'Emoji-ThirdPartyNotices.txt'),
  fs.readFileSync(path.join(root, 'Sources/Typeflux/WorkflowGallery/emoji/THIRD_PARTY_NOTICES.txt'), 'utf8').trimEnd() + '\n');
console.log(`${entries.length} base entries, ${all.length} fully-qualified sequences`);
