#!/usr/bin/env node
const fs = require('node:fs');
const {marked, TurndownService, gfm, prettier, htmlMinify, XMLParser, XMLBuilder, XMLValidator} = require('./vendor.cjs');
async function convert(text, mode, compact=false) {
  if (mode === 'md2html') return marked.parse(text, {gfm:true}).trimEnd();
  if (mode === 'html2md') { const service=new TurndownService({headingStyle:'atx', codeBlockStyle:'fenced'}); service.use(gfm); return service.turndown(text); }
  if (mode === 'htmlfmt') return compact ? await htmlMinify(text, {collapseWhitespace:true, conservativeCollapse:true, removeComments:true, minifyCSS:false, minifyJS:false}) : (await prettier.format(text,{parser:'html', htmlWhitespaceSensitivity:'strict', tabWidth:2})).trimEnd();
  if (mode === 'xmlfmt') {
    if (/<!DOCTYPE|<!ENTITY/i.test(text)) throw new Error('XML DTD and external entities are not supported');
    const valid=XMLValidator.validate(text); if(valid!==true) throw new Error(valid.err.msg);
    // Preserve mixed content, attributes and significant text whitespace in both modes.
    const opts={preserveOrder:true, ignoreAttributes:false, trimValues:false, parseTagValue:false, commentPropName:'#comment'};
    const tree=new XMLParser(opts).parse(text);
    let mixed=false;
    function clean(nodes,preserve=false) {
      const hasElements=nodes.some(n=>Object.keys(n).some(k=>k!==':@' && !k.startsWith('#') && !k.startsWith('?')));
      const hasText=nodes.some(n=>typeof n['#text']==='string' && n['#text'].trim()!=='');
      if(preserve || (hasElements && hasText)) mixed=true;
      return nodes.filter(n=>preserve || !hasElements || hasText || n['#text']===undefined || n['#text'].trim()!=='').map(n=> {
        const result={...n};
        for(const [k,v] of Object.entries(n)) if(Array.isArray(v)) result[k]=clean(v,preserve || n[':@']?.['@_xml:space']==='preserve');
        return result;
      });
    }
    const cleaned=clean(tree);
    return new XMLBuilder({...opts,format:!compact && !mixed,indentBy:'  '}).build(cleaned).trimEnd();
  }
  throw new Error('Unknown markup operation');
}
async function main(mode, query, selection) {
  const flag=['htmlfmt','xmlfmt'].includes(mode) ? query.match(/^(min|pretty)(?:\s+([\s\S]*))?$/) : null;
  const text=flag ? (flag[2] ?? selection ?? '') : (query || selection || '');
  if(!text) throw new Error('Type text after the keyword or select text first');
  return convert(text,mode,flag?.[1]==='min');
}
if(require.main===module) { (async()=> { try { const r=JSON.parse(fs.readFileSync(0,'utf8').split('\n')[0]||'{}'); console.log(await main(process.argv[2],process.argv[3]||'',r.selection)); } catch(e) { console.log(JSON.stringify({error:e.message})); process.exitCode=1; } })(); }
module.exports={convert,main};
