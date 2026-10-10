#!/usr/bin/env node
const fs = require('node:fs');
const styles = ['lowercase', 'uppercase', 'camelcase', 'capitalcase', 'constantcase', 'dotcase', 'headercase', 'nocase', 'paramcase', 'pascalcase', 'pathcase', 'sentencecase', 'snakecase', 'mockingcase'];
function convert(text, style) {
  const words = text.replace(/([\p{Ll}\d])([\p{Lu}])/gu, '$1 $2').replace(/([\p{Lu}])([\p{Lu}][\p{Ll}])/gu, '$1 $2').match(/[\p{L}\p{N}]+/gu) || [];
  const lower = words.map(w => w.toLowerCase());
  const caps = lower.map(w => w.charAt(0).toUpperCase() + w.slice(1));
  switch (style) {
    case 'lowercase': return text.toLowerCase();
    case 'uppercase': return text.toUpperCase();
    case 'camelcase': return lower[0] ? lower[0] + caps.slice(1).join('') : '';
    case 'capitalcase': return caps.join(' ');
    case 'constantcase': return lower.join('_').toUpperCase();
    case 'dotcase': return lower.join('.');
    case 'headercase': return caps.join('-');
    case 'nocase': return lower.join(' ');
    case 'paramcase': return lower.join('-');
    case 'pascalcase': return caps.join('');
    case 'pathcase': return lower.join('/');
    case 'sentencecase': return caps[0] ? [caps[0], ...lower.slice(1)].join(' ') : '';
    case 'snakecase': return lower.join('_');
    case 'mockingcase': { let n = 0; return Array.from(text).map(c => /\p{L}/u.test(c) ? (n++ % 2 ? c.toUpperCase() : c.toLowerCase()) : c).join(''); }
    default: throw new Error('Unknown case: ' + style);
  }
}
function main(query, selection) {
  const match = query.match(/^(\S+)(?:\s+([\s\S]*))?$/);
  const mode = match && styles.includes(match[1].toLowerCase()) ? match[1].toLowerCase() : null;
  const text = mode ? (match[2] ?? selection ?? '') : (query || selection || '');
  if (!text) throw new Error('Type: case camelcase hello world, or select text and type case');
  if (mode) return convert(text, mode);
  return JSON.stringify({items: styles.map(style => ({uid: style, title: convert(text, style), subtitle: style, arg: convert(text, style), action: 'copy'}))});
}
if (require.main === module) { try { const r = JSON.parse(fs.readFileSync(0, 'utf8').split('\n')[0] || '{}'); console.log(main(process.argv[2] || '', r.selection)); } catch(e) { console.log(JSON.stringify({error:e.message})); process.exitCode=1; } }
module.exports = {convert, main, styles};
