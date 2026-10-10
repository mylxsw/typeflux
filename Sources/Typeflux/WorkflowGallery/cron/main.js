#!/usr/bin/env node
const fs=require('node:fs');
const {cronstrue}=require('./vendor.cjs');
const months=['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
const days=['SUN','MON','TUE','WED','THU','FRI','SAT'];
function field(text,min,max,names=[],offset=0,special='') {
  if(text==='*' || (text==='?' && special)) return;
  if(special==='dom' && /^(L(?:-\d{1,2})?|LW|\d{1,2}W)$/.test(text)) {
    const n=Number(text.match(/\d+/)?.[0]);
    if(text.endsWith('W') && text!=='LW' && !(n>=1&&n<=31)) throw new Error('Nearest weekday must be 1–31');
    if(text.startsWith('L-') && !(n>=1&&n<=30)) throw new Error('Last-day offset must be 1–30');
    return;
  }
  const number=v=> { const i=names.indexOf(v); const n=i<0 ? (/^\d+$/.test(v)?Number(v):NaN) : i+offset; if(!(n>=min&&n<=max)) throw new Error('Out of range cron field: '+text); return n; };
  if(special==='dow' && /^(?:[1-7]|SUN|MON|TUE|WED|THU|FRI|SAT)(?:L|#[1-5])$/.test(text)) return;
  if(special==='dow' && text==='L') return;
  for(const part of text.split(',')) {
    const split=part.split('/'); if(split.length>2) throw new Error('Invalid step: '+text);
    if(split.length===2 && (!/^\d+$/.test(split[1]) || Number(split[1])<1 || Number(split[1])>max-min+1)) throw new Error('Invalid step: '+text);
    if(split[0]==='*') continue;
    const range=split[0].split('-'); if(range.length>2) throw new Error('Invalid range: '+text);
    range.forEach(number);
    if(range.length===2 && number(range[0])>number(range[1])) throw new Error('Descending ranges are not supported; use a comma list: '+text);
  }
}
function parse(expression,forced) {
  const aliases={'@yearly':'0 0 1 1 *','@annually':'0 0 1 1 *','@monthly':'0 0 1 * *','@weekly':'0 0 * * 0','@daily':'0 0 * * *','@midnight':'0 0 * * *','@hourly':'0 * * * *'};
  if(expression==='@reboot') { if(forced==='java') throw new Error('@reboot is Linux only'); return {mode:'linux',expression,description:'Run once at system startup'}; }
  expression=(aliases[expression.toLowerCase()] || expression).toUpperCase();
  const f=expression.trim().split(/\s+/), mode=forced || (f.length===5?'linux':'java');
  if(mode==='linux' && f.length!==5 || mode==='java' && ![6,7].includes(f.length)) throw new Error('Linux needs 5 fields; Java / Quartz needs 6 or 7');
  if(mode==='linux') {
    field(f[0],0,59); field(f[1],0,23); field(f[2],1,31); field(f[3],1,12,months,1); field(f[4],0,7,days,0);
  } else {
    field(f[0],0,59); field(f[1],0,59); field(f[2],0,23); field(f[3],1,31,[],0,'dom'); field(f[4],1,12,months,1); field(f[5],1,7,days,1,'dow'); if(f[6]) field(f[6],1970,2099);
    if((f[3]==='?')===(f[5]==='?')) throw new Error('Quartz requires ? in exactly one of day-of-month or day-of-week');
  }
  let described=f.join(' ');
  // Standalone Quartz L in day-of-week means Saturday.
  if(mode==='java' && f[5]==='L') { const normalized=[...f]; normalized[5]='7'; described=normalized.join(' '); }
  const language=process.env.TYPEFLUX_LANGUAGE||'en';
  const locale=language.startsWith('zh')?(language.includes('Hant')?'zh_TW':'zh_CN'):'en';
  let description=cronstrue.toString(described,{throwExceptionOnParseError:true,dayOfWeekStartIndexZero:mode==='linux',use24HourTimeFormat:true,locale});
  // Linux treats two restricted day fields as OR; most description libraries say AND.
  if(mode==='linux' && !f[2].startsWith('*') && !f[4].startsWith('*')) {
    const a=[...f],b=[...f]; a[4]='*'; b[2]='*';
    const opts={throwExceptionOnParseError:true,use24HourTimeFormat:true,locale};
    description=cronstrue.toString(a.join(' '),opts)+' OR '+cronstrue.toString(b.join(' '),opts);
  }
  return {mode,expression:f.join(' '),description};
}
function generate(query) {
  let linux,java;
  let m;
  if((m=query.match(/^every\s+(\d+)\s+(minutes?|hours?)$/i))) {
    const n=Number(m[1]), hours=m[2].toLowerCase().startsWith('hour');
    if(n<1 || n>(hours?23:59)) throw new Error('Interval must be 1–59 minutes or 1–23 hours');
    linux=hours?`0 */${n} * * *`:`*/${n} * * * *`; java=hours?`0 0 */${n} * * ?`:`0 */${n} * * * ?`;
  } else if((m=query.match(/^(daily|weekdays|weekly\s+(sun|mon|tue|wed|thu|fri|sat))\s+(\d{1,2}):(\d{2})$/i))) {
    const h=Number(m[3]),min=Number(m[4]); if(h>23||min>59) throw new Error('Time must be 00:00–23:59');
    const day=m[1].toLowerCase()==='daily'?'*':m[1].toLowerCase()==='weekdays'?'MON-FRI':m[2].toUpperCase();
    linux=`${min} ${h} * * ${day}`; java=`0 ${min} ${h} ${day==='*'?'*':'?'} * ${day==='*'?'?':day}`;
  } else throw new Error('Try: cron every 5 minutes; cron daily 09:30; cron weekdays 09:00; cron weekly mon 08:00');
  return JSON.stringify({items:[{uid:'linux',title:linux,subtitle:'Linux · '+parse(linux,'linux').description,arg:linux,action:'copy'},{uid:'java',title:java,subtitle:'Java / Quartz · '+parse(java,'java').description,arg:java,action:'copy'}]});
}
function main(query,selection) {
  if(!query && !selection) return generate('daily 09:00');
  let input=(query||selection).trim();
  if(/^(every|daily|weekdays|weekly)\b/i.test(input)) return generate(input);
  const prefix=input.match(/^(linux|java|quartz)(?:\s+|$)/i); let forced;
  if(prefix) {forced=prefix[1].toLowerCase()==='linux'?'linux':'java'; input=input.slice(prefix[0].length)||selection||'';}
  const result=parse(input,forced);
  return `${result.mode==='linux'?'Linux (5 fields)':'Java / Quartz (6–7 fields)'}\n${result.expression}\n${result.description}\nTimezone: determined by the scheduler; no system jobs are created.`;
}
if(require.main===module) { try { const r=JSON.parse(fs.readFileSync(0,'utf8').split('\n')[0]||'{}'); console.log(main(process.argv[2]||'',r.selection)); } catch(e) {console.log(JSON.stringify({error:String(e.message||e)})); process.exitCode=1;} }
module.exports={field,parse,generate,main};
