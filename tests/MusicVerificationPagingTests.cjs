'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const file=path.resolve(__dirname,'../integrations/service_runtime/netease_bridge.cjs');
const source=fs.readFileSync(file,'utf8').split('\ntry {\n  const request=readRequest();')[0];
const api=new Function('require','__dirname',source+'\nreturn {collectMusicPages,projectItem,context:value=>{readContext=value;}};')(require,path.dirname(file));
const id=i=>i.toString(16).padStart(32,'0');
const records=Array.from({length:32},(_,i)=>({encryptedId:id(i+1),name:'Song '+i,
 ar:[{name:'Artist'}],al:{name:'Album'},extraBusinessField:'x'.repeat(4000)}));
async function collect(items,extra={}) {
 return api.collectMusicPages(async offset=>({items:items.slice(offset,offset+100),total:items.length,hasMore:offset+100<items.length}),
  {kind:'song',pageSize:100,...extra});
}
(async()=>{
 api.context({isWrite:false,verification:false});
 const display=records.map(r=>api.projectItem(r,'song'));
 const first=await collect(display);
 assert.equal(first.complete,false);assert.equal(first.pagination.state,'budget_exhausted');assert(first.items.length<32);
 api.context({isWrite:false,verification:true});
 const compact=records.map(r=>api.projectItem(r,'song'));
 assert(compact.every(r=>!Object.hasOwn(r,'provider_record')));
 const verified=await collect(compact,{maxBytes:Infinity});
 assert.equal(verified.complete,true);assert.equal(verified.items.length,32);
 const large=Array.from({length:1101},(_,i)=>({song_id:id(i+1),name:'Song'}));
 assert.equal((await collect(large,{maxBytes:Infinity})).complete,true);
 const continuation=await api.collectMusicPages(async offset=>({items:compact.slice(offset),total:32,hasMore:false}),
  {kind:'song',pageSize:100,startOffset:30,maxBytes:Infinity});
 assert.equal(continuation.complete,false);assert.equal(continuation.pagination.state,'continuation_end');
 let calls=0;
 const drift=await api.collectMusicPages(async()=>({items:++calls===1?compact:compact.toReversed(),total:32,hasMore:false}),
  {kind:'song',pageSize:100,maxBytes:Infinity});
 assert.equal(drift.complete,false);assert.equal(drift.pagination.state,'drift');
 const duplicate=await collect([compact[0],compact[0]],{maxBytes:Infinity});
 assert.equal(duplicate.complete,false);
 console.log(JSON.stringify({status:'PASS',rich_records:32,large_membership:1101,ordered_sweeps:true,real_network:0}));
})().catch(e=>{console.error(e);process.exitCode=1;});
