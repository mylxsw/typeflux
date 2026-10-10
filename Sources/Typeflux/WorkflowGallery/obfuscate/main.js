#!/usr/bin/env node
const fs=require('node:fs');
function mask(text, start=0, end=0, percent=100, character='*') {
  const chars=Array.from(text);
  if(![start,end,percent].every(Number.isInteger) || start<0 || end<0 || percent<0 || percent>100 || Array.from(character).length!==1) throw new Error('Keep counts must be nonnegative integers; percent is 0–100; mask is one character');
  const available=Math.max(0,chars.length-start-end), count=Math.ceil(available*percent/100);
  return chars.map((c,i)=>i>=start && i<start+count ? character : c).join('');
}
function main(query,selection) {
  const opts={start:0,end:0,percent:100,mask:'*'};
  let text=query;
  while(text.startsWith('--')) {
    const m=text.match(/^--(keep-start|keep-end|percent|mask)\s+(\S+)(?:\s+|$)/);
    if(!m) { if(text.startsWith('-- ')) { text=text.slice(3); break; } throw new Error('Options: --keep-start N --keep-end N --percent N --mask X'); }
    const key=m[1]==='keep-start'?'start':m[1]==='keep-end'?'end':m[1];
    opts[key]=key==='mask'?m[2]:Number(m[2]); text=text.slice(m[0].length);
  }
  text=text || selection || '';
  if(!text) throw new Error('Type: obfuscate --keep-start 3 --keep-end 4 13812345678 (masking is not encryption)');
  return mask(text,opts.start,opts.end,opts.percent,opts.mask);
}
if(require.main===module) { try { const r=JSON.parse(fs.readFileSync(0,'utf8').split('\n')[0]||'{}'); console.log(main(process.argv[2]||'',r.selection)); } catch(e) { console.log(JSON.stringify({error:e.message})); process.exitCode=1; } }
module.exports={mask,main};
