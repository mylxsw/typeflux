#!/usr/bin/env node
const fs=require('node:fs');
const {QRCode}=require('./vendor.cjs');
async function generate(text) {
  if(!text) throw new Error('Type qr <text>, or select text first');
  return QRCode.toDataURL(text,{type:'image/png',errorCorrectionLevel:'M',scale:8,margin:4});
}
if(require.main===module) { (async()=> { try { const r=JSON.parse(fs.readFileSync(0,'utf8').split('\n')[0]||'{}'); console.log(await generate(process.argv[2]||r.selection||'')); } catch(e) { console.log(JSON.stringify({error:e.message})); process.exitCode=1; } })(); }
module.exports={generate};
