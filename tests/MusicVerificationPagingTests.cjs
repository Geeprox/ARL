'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const file=path.resolve(__dirname,'../integrations/service_runtime/netease_bridge.cjs');
const source=fs.readFileSync(file,'utf8').split('\ntry {\n  const request=readRequest();')[0];
const api=new Function('require','__dirname',source+'\nreturn {READ_SPECS,projectReadManifestReply,requiredReadStages,collectMusicPages,collectPlaylistMetadata,projectItem,projectCloudSongs,context:value=>{readContext=value;}};')(require,path.dirname(file));
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
 const first=await collect(display,{maxBytes:98304});
 assert.equal(first.complete,false);assert.equal(first.pagination.state,'budget_exhausted');assert(first.items.length<32);
 const richComplete=await collect(display);
 assert.equal(richComplete.complete,true);assert.equal(richComplete.items.length,32);
 assert(Buffer.byteLength(JSON.stringify(richComplete.items))>98304);
 assert(richComplete.items.every(r=>r.provider_record.fields.extraBusinessField==='x'.repeat(4000)));
 const course=Array.from({length:252},(_,i)=>({...display[i%display.length],song_id:id(i+10000)}));
 const courseComplete=await collect(course);assert.equal(courseComplete.complete,true);assert.equal(courseComplete.items.length,252);
 assert.equal(courseComplete.pagination.pages,6);assert.equal(courseComplete.pagination.state,'stable_observed');
 api.context({isWrite:false,verification:false,arguments:{}});
 assert.equal(api.projectCloudSongs({code:200,data:{songs:[records[0]],hasMore:true,cursor:'next',total:200001}}).cloud_page.total,200001);
 api.context({isWrite:false,verification:true});
 const compact=records.map(r=>api.projectItem(r,'song'));
 assert(compact.every(r=>!Object.hasOwn(r,'provider_record')));
 const verified=await collect(compact,{maxBytes:Infinity});
 assert.equal(verified.complete,true);assert.equal(verified.items.length,32);
 assert.deepEqual(api.requiredReadStages('playlist_detail',true),['playlist_detail']);
 assert.deepEqual(api.requiredReadStages('playlist_detail',false),['playlist_detail','tracks']);
 const spec=api.READ_SPECS.playlist_detail;
 const catalog={manifests:{root:{methods:[],sub_resources:[{name:spec.group,path:spec.group}]},
  [spec.group]:{methods:[{name:spec.method??'detail',path:spec.path,http_method:spec.httpMethod??'GET',auth_required:true,auth_provider:'netease',parameters:[{name:'playlistId',type:'string',in:'query',required:true}]}],sub_resources:[]}}};
 api.context({operation:'playlist_detail',metadataOnly:true,isWrite:false,arguments:{playlist_id:id(999)}});
 assert.equal(api.projectReadManifestReply(catalog).manifests[spec.group].methods.length,1);
 api.context({operation:'playlist_detail',metadataOnly:false,isWrite:false,arguments:{playlist_id:id(999)}});
 assert.throws(()=>api.projectReadManifestReply(catalog));
 const wrongAuth=structuredClone(catalog);wrongAuth.manifests[spec.group].methods[0].auth_required=false;
 api.context({operation:'playlist_detail',metadataOnly:true,isWrite:false,arguments:{playlist_id:id(999)}});
 assert.throws(()=>api.projectReadManifestReply(wrongAuth));
 let metadataCalls=0;
 const metadata={playlist_id:id(999),name:'Name',track_count:200001,provider_record:{fields:{describe:'Description'}}};
 const observed=await api.collectPlaylistMetadata(async operation=>{assert.equal(operation,'playlist_detail');metadataCalls++;return metadata;});
 assert.equal(observed.track_count,200001);assert.equal(metadataCalls,2);
 let emptyDescriptionRead=0;
 await api.collectPlaylistMetadata(async()=>({...metadata,provider_record:{fields:{describe:emptyDescriptionRead++===0?null:''}}}));
 let changed=false;
 await assert.rejects(()=>api.collectPlaylistMetadata(async()=>({ ...metadata,name:(changed=!changed)?'Before':'After'})),/playlist_metadata_changed/);
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
 console.log(JSON.stringify({status:'PASS',rich_records:32,large_membership:1101,rich_course_records:252,ordered_sweeps:true,real_network:0}));
})().catch(e=>{console.error(e);process.exitCode=1;});
