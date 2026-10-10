#!/usr/bin/env node
const fs=require('node:fs');
function decode(part) {
  if (!/^[A-Za-z0-9_-]+$/.test(part) || part.length%4===1) throw new Error('Invalid JWT base64url segment');
  const bytes=Buffer.from(part,'base64url');
  if(bytes.toString('base64url')!==part) throw new Error('Invalid JWT base64url segment');
  const value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  if(!value || typeof value!=='object' || Array.isArray(value)) throw new Error('JWT header and payload must be objects');
  return value;
}
function parse(text, now=Date.now()) {
  const parts=text.trim().replace(/^Bearer\s+/i,'').split('.');
  if(parts.length!==3 || (parts[2] && !/^[A-Za-z0-9_-]+$/.test(parts[2]))) throw new Error('Expected a three-part JWT (JWE is not supported)');
  const header=decode(parts[0]), payload=decode(parts[1]);
  const dates={};
  for(const key of ['iat','nbf','exp']) if(Object.hasOwn(payload,key)) {
    if(typeof payload[key]!=='number' || !Number.isFinite(payload[key]) || Math.abs(payload[key])>8640000000000) throw new Error(key+' must be a numeric Unix timestamp');
    dates[key]=new Date(payload[key]*1000).toISOString();
  }
  return JSON.stringify({warning:'Decoded only; signature, issuer and audience are NOT verified.',header,payload,dates,expired:typeof payload.exp==='number' ? payload.exp*1000<=now : null,notYetValid:typeof payload.nbf==='number' ? payload.nbf*1000>now : null},null,2);
}
if(require.main===module) { try { const r=JSON.parse(fs.readFileSync(0,'utf8').split('\n')[0]||'{}'); console.log(parse(process.argv[2]||r.selection||'')); } catch(e) { console.log(JSON.stringify({error:e.message})); process.exitCode=1; } }
module.exports={parse};
