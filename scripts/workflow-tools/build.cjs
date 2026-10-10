const fs=require('node:fs'),path=require('node:path'),esbuild=require('esbuild');
const root=path.resolve(__dirname,'../../Sources/Typeflux/WorkflowGallery');
const entries={
 data:"exports.YAML=require('yaml');exports.TOML=require('@iarna/toml');Object.assign(exports,require('fast-xml-parser'));",
 markup:"exports.marked=require('marked').marked;exports.TurndownService=require('turndown');exports.gfm=require('turndown-plugin-gfm').gfm;exports.prettier=require('prettier/standalone');const html=require('prettier/plugins/html');const format=exports.prettier.format;exports.prettier={format:(text,opts)=>format(text,{...opts,plugins:[html]})};exports.htmlMinify=require('html-minifier-terser').minify;Object.assign(exports,require('fast-xml-parser'));",
 qr:"exports.QRCode=require('qrcode');",
 cron:"const c=require('cronstrue');const zh=require('cronstrue/locales/zh_CN');const tw=require('cronstrue/locales/zh_TW');c.default.locales.zh_CN=new zh.zh_CN();c.default.locales.zh_TW=new tw.zh_TW();exports.cronstrue=c.default;"
};
(async()=> {for(const [id,source] of Object.entries(entries)) {
 const result=await esbuild.build({stdin:{contents:source,resolveDir:__dirname,sourcefile:id+'.cjs'},outfile:path.join(root,id,'vendor.cjs'),bundle:true,minify:true,platform:'node',target:'node18',metafile:true,legalComments:'eof'});
 const packages=new Set();for(const file of Object.keys(result.metafile.inputs)) {const m=file.match(/node_modules\/((?:@[^/]+\/)?[^/]+)/);if(m)packages.add(m[1]);}
 let notices='Bundled dependencies for offline use. Generated with esbuild; do not edit vendor.cjs.\n\n';
 for(const name of [...packages].sort()) {const dir=path.join(__dirname,'node_modules',name),pkg=JSON.parse(fs.readFileSync(path.join(dir,'package.json'),'utf8'));notices+=`${name} ${pkg.version} (${pkg.license || 'see license'})\n`;
 const file=fs.readdirSync(dir).find(f=>/^licen[sc]e(?:\.|$)/i.test(f)); if(!file)throw new Error('Missing license for '+name);notices+=fs.readFileSync(path.join(dir,file),'utf8')+'\n\n';}
 fs.writeFileSync(path.join(root,id,'THIRD_PARTY_NOTICES.txt'),notices);
}
 const data=require('emojilib');
 for(const language of ['zh','zh-Hant']) {
 const annotations=require('cldr-annotations-full/annotations/'+language+'/annotations.json').annotations.annotations;
 for(const [emoji,tags] of Object.entries(data)) {const entry=annotations[emoji]||annotations[emoji.replace(/\ufe0f/g,'')];if(entry)tags.push(...(entry.tts||[]),...(entry.default||[]));}
 }
 for(const emoji of Object.keys(data))data[emoji]=[...new Set(data[emoji])];
 fs.writeFileSync(path.join(root,'emoji','emoji.json'),JSON.stringify(data)+'\n');
 let emojiNotices='';for(const name of ['emojilib','cldr-annotations-full']) {const dir=path.join(__dirname,'node_modules',name),pkg=require(path.join(dir,'package.json'));emojiNotices+=name+' '+pkg.version+'\n'+fs.readFileSync(path.join(dir,'LICENSE'),'utf8')+'\n';}
 fs.writeFileSync(path.join(root,'emoji','THIRD_PARTY_NOTICES.txt'),emojiNotices);
})().catch(e=> {console.error(e);process.exit(1);});
