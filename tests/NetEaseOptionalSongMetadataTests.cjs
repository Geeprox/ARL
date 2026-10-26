// Production projector, synthetic provider records: no process, network or credential.
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
function api(file){const s=fs.readFileSync(file,'utf8'),i=s.lastIndexOf('\ntry {\n  const request=readRequest();');return new Function('require','__dirname',s.slice(0,i)+'\nreturn {projectReadValue,set(c){readContext=c;diagnostic=null;}};')(require,path.dirname(path.resolve(file)));}
const current=api('integrations/service_runtime/netease_bridge.cjs');
const previous=api('build/audit/search-text-failure-20261012/BEFORE-FIX-netease_bridge.cjs');
const old36=api('build/audit/business-guards-20261012/product-release37/installation/stage/ARL.app/Contents/Resources/ServiceRuntime/Bridge/netease_bridge.cjs');
const rows=()=>Array.from({length:20},(_,i)=>({encryptedId:(i+1).toString(16).padStart(32,'0'),name:'Synthetic '+i,ar:[{name:'Artist'}],al:{name:'Album'}}));
const context={operation:'search',isWrite:false};let checks=0;
function page(records,write=false,engine=current){engine.set({...context,isWrite:write});return engine.projectReadValue({code:200,data:{records,recordCount:300}},'search');}
const actual=rows();actual[4].al.name='';
for(const engine of [old36,previous])assert.throws(()=>page(actual,false,engine),e=>e.code==='invalid_result_text');checks++;
let p=page(actual);assert.equal(p.items.length,20);assert.equal(p.total,300);assert.equal(p.items[4].metadata.album,null);assert.deepEqual(p.items[4].metadata.unknown_fields,['album','recording_version','duration_ms']);assert.deepEqual(p.items.map(x=>x.song_id),actual.map(x=>x.encryptedId));checks++;
for(const album of [null,{}, {name:null},{name:' \t\r\n '},{name:17}]){const r=rows();r[4].al=album;p=page(r);assert.equal(p.items.length,20);assert.equal(p.items[4].metadata.album,null);assert.ok(p.items[4].metadata.unknown_fields.includes('album'));checks++;}
for(const ar of [[],[{name:''}],[{name:'Artist'},{name:null}],null,{},Array(21).fill({name:'Artist'})]){const r=rows();r[4].ar=ar;p=page(r);assert.equal(p.items.length,20);assert.equal(p.items[4].metadata.artists,null);assert.ok(p.items[4].metadata.unknown_fields.includes('artists'));checks++;}
const newline=rows();newline[4].al.name='First\r\nSecond';newline[4].ar[0].name='First\tSecond';p=page(newline);assert.equal(p.items[4].metadata.album,'First Second');assert.deepEqual(p.items[4].metadata.artists,['First Second']);checks++;
const bad=rows();bad[4].al.name='x\u0000y';bad[4].ar[0].name='中'.repeat(67);p=page(bad);assert.equal(p.items[4].metadata.album,null);assert.equal(p.items[4].metadata.artists,null);checks++;
const extensions=rows();extensions[4].futureProviderField={unknown:true};p=page(extensions);assert.equal('futureProviderField' in p.items[4],false);checks++;
assert.throws(()=>page(actual,true),e=>e.code==='invalid_result_text');assert.throws(()=>page(newline,true),e=>e.code==='invalid_result_text');checks++;
for(const change of [r=>r[4].encryptedId='invalid',r=>r[4].name='',r=>r[4].name='bad\nname',r=>r[4].encryptedId=r[3].encryptedId]){const r=rows();change(r);assert.throws(()=>page(r));checks++;}
assert.deepEqual(page(rows()),page(rows(),false,previous));checks++;
process.stdout.write(JSON.stringify({status:'PASS',checks,rows_preserved:20,old36_and38_reproduce_same_empty_album_rejection:true,write_guards_unchanged:true,real_queries:0,credentials:0})+'\n');
