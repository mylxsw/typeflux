#!/usr/bin/env node
const fs=require('node:fs');
const data=require('./emoji.json');
function search(query) {
  const words=query.trim().toLowerCase().replace(/:/g,'').split(/\s+/).filter(Boolean);
  const matches=Object.entries(data).filter(([emoji,tags])=>words.every(w=>emoji.includes(w)||tags.some(t=>t.toLowerCase().includes(w))));
  matches.sort(([a,at],[b,bt])=>Number(bt.some(t=>words.includes(t.toLowerCase())))-Number(at.some(t=>words.includes(t.toLowerCase()))));
  const items=matches.slice(0,80).map(([emoji,tags])=>({uid:emoji,title:emoji+'  '+tags[0],subtitle:tags.slice(1,7).join(' · '),arg:emoji,action:'copy'}));
  if(!items.length) items.push({title:'No matching emoji',subtitle:'Try English or Chinese keywords, or paste an emoji',valid:false});
  return JSON.stringify({items});
}
if(require.main===module) {try {const r=JSON.parse(fs.readFileSync(0,'utf8').split('\n')[0]||'{}'); console.log(search(process.argv[2]||r.selection||''));} catch(e) {console.log(JSON.stringify({error:e.message}));process.exitCode=1;}}
module.exports={search};
