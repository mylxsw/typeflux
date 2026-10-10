#!/usr/bin/env node
const fs = require('node:fs');
const {YAML, TOML, XMLParser, XMLBuilder, XMLValidator} = require('./vendor.cjs');
const formats = ['yaml', 'toml', 'json', 'xml'];
function convert(text, from, to) {
  if (!formats.includes(from) || !formats.includes(to)) throw new Error('Formats: yaml, toml, json, xml');
  let value;
  if (from === 'json') value = JSON.parse(text);
  if (from === 'yaml') {
    const doc=YAML.parseDocument(text,{uniqueKeys:true});
    if(doc.errors.length || doc.warnings.length) throw new Error((doc.errors[0]||doc.warnings[0]).message);
    value=doc.toJS({maxAliasCount:100,mapAsMap:true});
    function plain(v) {
      if(v instanceof Map) { const o=Object.create(null); for(const [k,item] of v) { if(typeof k!=='string') throw new Error('YAML conversion requires string mapping keys'); o[k]=plain(item); } return o; }
      if(Array.isArray(v)) return v.map(plain);
      if(typeof v==='number' && !Number.isFinite(v)) throw new Error('Non-finite YAML numbers cannot be converted');
      return v;
    }
    value=plain(value);
  }
  if (from === 'toml') value = TOML.parse(text);
  if (from === 'xml') {
    if (/<!DOCTYPE|<!ENTITY/i.test(text)) throw new Error('XML DTD and external entities are not supported');
    const valid = XMLValidator.validate(text);
    if (valid !== true) throw new Error(valid.err.msg);
    value = new XMLParser({ignoreAttributes:false, attributeNamePrefix:'@_', trimValues:false, parseTagValue:false}).parse(text);
  }
  // TOML dates become ISO strings; XML attributes use @_, text uses #text.
  value = JSON.parse(JSON.stringify(value));
  if (to === 'json') return JSON.stringify(value, null, 2);
  if (to === 'yaml') return YAML.stringify(value).trimEnd();
  if (to === 'toml') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('TOML requires a top-level object');
    function noNull(v) { if (v === null) throw new Error('TOML cannot represent null'); if (typeof v === 'object') Object.values(v).forEach(noNull); }
    noNull(value); return TOML.stringify(value).trimEnd();
  }
  const builder = new XMLBuilder({ignoreAttributes:false, attributeNamePrefix:'@_', format:true, suppressEmptyNode:false});
  // A single object key can be the XML root. Other values get a <root> wrapper.
  const object = value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === 1 && !Array.isArray(Object.values(value)[0]) ? value : {root:value};
  const xml = builder.build(object).trimEnd();
  const valid = XMLValidator.validate(xml);
  if (valid !== true) throw new Error('Cannot represent this value as XML: ' + valid.err.msg);
  return xml;
}
function main(query, selection) {
  const match = query.match(/^(yaml|toml|json|xml)\s+(?:to\s+)?(yaml|toml|json|xml)(?:\s+([\s\S]*))?$/i);
  if (!match) throw new Error('Type: data yaml json <text>, or select text and type data yaml json');
  const text = match[3] ?? selection ?? '';
  if (!text) throw new Error('No data to convert');
  return convert(text, match[1].toLowerCase(), match[2].toLowerCase());
}
if (require.main === module) { try { const r=JSON.parse(fs.readFileSync(0,'utf8').split('\n')[0]||'{}'); console.log(main(process.argv[2]||'',r.selection)); } catch(e) { console.log(JSON.stringify({error:e.message})); process.exitCode=1; } }
module.exports={convert,main};
