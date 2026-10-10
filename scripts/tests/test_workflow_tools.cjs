const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'../../Sources/Typeflux/WorkflowGallery');
const load=id=>require(path.join(root,id,'main.js'));
const run=(id,args,selection='')=>spawnSync(process.execPath,[path.join(root,id,'main.js'),...args],{input:JSON.stringify({selection})+'\n',encoding:'utf8',env:{PATH:process.env.PATH,TYPEFLUX_LANGUAGE:'en'}});

test('all 14 naming styles handle acronyms, punctuation and Unicode',()=> {
 const m=load('case'),input='XMLHttpRequest foo-BAR';
 const expected=['xmlhttprequest foo-bar','XMLHTTPREQUEST FOO-BAR','xmlHttpRequestFooBar','Xml Http Request Foo Bar','XML_HTTP_REQUEST_FOO_BAR','xml.http.request.foo.bar','Xml-Http-Request-Foo-Bar','xml http request foo bar','xml-http-request-foo-bar','XmlHttpRequestFooBar','xml/http/request/foo/bar','Xml http request foo bar','xml_http_request_foo_bar','xMlHtTpReQuEsT fOo-BaR'];
 m.styles.forEach((style,i)=>assert.equal(m.convert(input,style),expected[i],style));
 assert.equal(m.main('camelcase','hello world'),'helloWorld');
 assert.equal(m.convert('你好-world','snakecase'),'你好_world');
 assert.equal(JSON.parse(m.main('', 'helloWorld')).items.length,14);
});

test('all 12 format directions convert common structured data',()=> {
 const {convert}=load('data'),obj={name:'Typeflux',count:3,enabled:true,items:['a','b']};
 const json=JSON.stringify(obj),sources={json,yaml:convert(json,'json','yaml'),toml:convert(json,'json','toml'),xml:convert(json,'json','xml')};
 for(const [from,text] of Object.entries(sources)) for(const to of ['yaml','toml','json','xml']) if(from!==to) {
  const result=convert(text,from,to);assert.ok(result.length,from+' to '+to);
  if(to==='json') assert.equal(JSON.parse(result)[from==='xml'?'root':'name'] ? true:false,true);
 }
 assert.deepEqual(JSON.parse(convert(sources.yaml,'yaml','json')),obj);
 assert.deepEqual(JSON.parse(convert(sources.toml,'toml','json')),obj);
 assert.equal(convert('{"a":1}','json','toml').trim(),'a = 1');
 assert.equal(JSON.parse(convert('<root key="v">text</root>','xml','json')).root['@_key'],'v');
 assert.throws(()=>convert('{"a":null}','json','toml'),/null/);
 assert.throws(()=>convert('[]','json','toml'),/top-level/);
 assert.throws(()=>convert('a: 1\na: 2','yaml','json'));
 assert.throws(()=>convert('a: !unknown hi','yaml','json'));
 assert.throws(()=>convert('? [a, b]\n: value','yaml','json'));
 assert.throws(()=>convert('a: .nan','yaml','json'),/Non-finite/);
 assert.throws(()=>convert('<!DOCTYPE x [<!ENTITY a SYSTEM "secret">]><x>&a;</x>','xml','json'),/DTD/);
 assert.throws(()=>convert('<a><b></a>','xml','json'));
});

test('Markdown and HTML conversion and formatting preserve meaningful content',async()=> {
 const m=load('markup');
 assert.equal(await m.convert('# Hello\n\n**world**','md2html'),'<h1>Hello</h1>\n<p><strong>world</strong></p>');
 assert.equal(await m.convert('<h1>Hello</h1><p><strong>world</strong></p>','html2md'),'# Hello\n\n**world**');
 assert.equal(await m.main('md2html','min'),'<p>min</p>');
 const table=await m.convert(await m.convert('| Name | Value |\n| --- | --- |\n| a | 1 |','md2html'),'html2md');assert.ok(table.includes('| Name | Value |'));assert.ok(table.includes('| a | 1 |'));
 assert.match(await m.convert('<del>removed</del>','html2md'),/~removed~/);
 const pretty=await m.convert('<div><span>hi</span></div>','htmlfmt');assert.ok(pretty.includes('hi'));
 const html='<pre>  a\n b </pre><script>const x = "  hi  ";</script>';
 const min=await m.convert(html,'htmlfmt',true);assert.ok(min.includes('  a\n b '));assert.ok(min.includes('"  hi  "'));
 assert.equal(await m.convert('<root>\n  <a>1</a>\n  <b key="&amp;">2</b>\n</root>','xmlfmt',true),'<root><a>1</a><b key="&amp;">2</b></root>');
 const mixed='<p>Hello <b>world</b> !</p>';
 assert.equal(await m.convert(mixed,'xmlfmt'),mixed);
 assert.equal(await m.convert('<p xml:space="preserve">  a  </p>','xmlfmt'),'<p xml:space="preserve">  a  </p>');
 await assert.rejects(()=>m.convert('<root>','xmlfmt'));
});

test('Base64 and URL modes accept selection controls and reject malformed data',()=> {
 assert.equal(run('codec',['base64','-d'],'5L2g5aW9').stdout.trim(),'你好');
 assert.equal(run('codec',['base64','-e'],'你好').stdout.trim(),'5L2g5aW9');
 assert.equal(run('codec',['url','-e --form a b&c']).stdout.trim(),'a+b%26c');
 assert.equal(run('codec',['url','-d --form a+b%26c']).stdout.trim(),'a b&c');
 for(const value of ['!!!!','a','ab==','/w==','a=ab','aGVsbG8==='])assert.equal(run('codec',['base64','-d '+value]).status,1,value);
 assert.equal(run('codec',['base64','-d aGVsbG8']).stdout.trim(),'hello');
 assert.equal(run('codec',['url','-d %ZZ']).status,1);
});

test('JWT parsing keeps trust warning and correctly interprets timestamps',()=> {
 const {parse}=load('jwt'),enc=v=>Buffer.from(JSON.stringify(v)).toString('base64url');
 const token=enc({alg:'none'})+'.'+enc({sub:'123',exp:100,nbf:50,iat:1})+'.';
 const result=JSON.parse(parse('Bearer '+token,75000));assert.equal(result.expired,false);assert.equal(result.notYetValid,false);assert.equal(result.dates.exp,'1970-01-01T00:01:40.000Z');assert.match(result.warning,/NOT verified/);
 assert.equal(JSON.parse(parse(token,100000)).expired,true);
 assert.equal(JSON.parse(parse(token,49000)).notYetValid,true);
 for(const text of ['no.token',token+'.more','@@.'+enc({})+'.',enc([])+'.'+enc({})+'.',enc({})+'.'+enc({exp:'100'})+'.'])assert.throws(()=>parse(text));
});

test('QR generator produces a PNG with no network service',async()=> {
 const m=load('qr'),data=await m.generate('你好 Typeflux');assert.ok(data.startsWith('data:image/png;base64,'));
 const bytes=Buffer.from(data.split(',')[1],'base64');assert.equal(bytes.subarray(1,4).toString(),'PNG');assert.ok(bytes.readUInt32BE(16)>100);
 await assert.rejects(()=>m.generate(''));await assert.rejects(()=>m.generate('x'.repeat(10000)));
});

test('Cron separates Linux and Quartz weekday semantics and special day operators',()=> {
 const m=load('cron');
 assert.match(m.parse('0 9 * * 1').description,/Monday/);
 assert.match(m.parse('0 0 9 ? * 1').description,/Sunday/);
 assert.match(m.parse('0 0 9 ? * 2').description,/Monday/);
 assert.match(m.parse('0 9 * * 7').description,/Sunday/);
 assert.match(m.parse('0 9 1 * MON').description,/ OR /);
 assert.match(m.parse('0 0 9 L * ?').description,/last day/);
 assert.match(m.parse('0 0 9 15W * ?').description,/weekday/);
 assert.match(m.parse('0 0 9 LW * ?').description,/last weekday/);
 assert.match(m.parse('0 0 9 ? * 6#3').description,/third Friday/);
 assert.match(m.parse('0 0 9 ? * 6L 2026').description,/last Friday.*2026/);
 assert.match(m.parse('0 0 9 L-3 * ?').description,/3 days before/);
 assert.match(m.parse('0 0 9 ? * L').description,/Saturday/);
 assert.equal(m.parse('@hourly').mode,'linux');assert.equal(m.parse('@reboot').expression,'@reboot');
 const generated=JSON.parse(m.generate('weekdays 09:30')).items;assert.deepEqual(generated.map(i=>i.title),['30 9 * * MON-FRI','0 30 9 ? * MON-FRI']);
 assert.equal(JSON.parse(m.generate('every 5 minutes')).items[0].title,'*/5 * * * *');
 assert.match(m.main('java','0 0 9 ? * MON'),/Monday/);
 for(const cron of ['60 * * * *','0 24 * * *','*/0 * * * *','0 0 9 * * MON','0 0 9 ? * ?','0 0 9 ? * 8','0 0 9 32W * ?','0 0 9 ? * 6#6','0 0 9 ? * MON 2100','0 0 * FOO *','0 0 31-1 * *'])assert.throws(()=>m.parse(cron),cron);
 assert.throws(()=>m.generate('daily 25:00'));
});

test('Emoji supports English, Chinese and joined Unicode sequences',()=> {
 const m=load('emoji');
 assert.ok(JSON.parse(m.search('smile')).items.some(i=>i.arg==='😀'));
 assert.ok(JSON.parse(m.search('笑')).items.some(i=>i.arg));
 assert.ok(JSON.parse(m.search('火箭')).items.some(i=>i.arg==='🚀'));
 assert.equal(JSON.parse(m.search('👩‍💻')).items[0].arg,'👩‍💻');
 assert.equal(JSON.parse(m.search('no-such-emoji-xyz')).items[0].valid,false);
 assert.equal(JSON.parse(m.search('')).items.length,80);
});

test('Obfuscation masks Unicode and validates options',()=> {
 const m=load('obfuscate');assert.equal(m.main('--keep-start 3 --keep-end 4 13812345678'),'138****5678');
 assert.equal(m.main('--percent 50 secret'),'***ret');
 assert.equal(m.main('--keep-end 1 --mask •','你好世界'),'•••界');
 assert.equal(m.mask('short',10,0),'short');assert.equal(m.mask('abc',0,0,0),'abc');
 for(const query of ['--percent 101 secret','--keep-start -1 secret','--mask XX secret','--percent 1.5 secret'])assert.throws(()=>m.main(query));
});
