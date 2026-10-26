"use strict";
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=process.cwd(),srcPath=path.join(root,'integrations/service_runtime/netease_bridge.cjs');
const src=fs.readFileSync(srcPath,'utf8'),setup=src.slice(0,src.lastIndexOf('\ntry {\n  const request=readRequest();'));
// Execute the production command boundary, projectRead/songMetadata and the exact
// read-result assembly from finish; omit only encrypted state/frame emission.
const finishPart=src.slice(src.indexOf('function finish(request) {'),src.indexOf('  const stored={};',src.indexOf('function finish(request) {')))
 .replace('function finish(request)','function fixtureFinish(request)')+'return readResult;\n}\n';
const api=new Function('require','__dirname',setup+'\n'+finishPart+`
return {async wire(operation,raw,offset=0) {
 inspectSession=()=>({present:true});exitCode=0;finished=false;
 const spec=READ_SPECS[operation];
 readContext={operation,isWrite:false,arguments:operation==='search'?{keyword:'Synthetic',offset}:{},results:{},
 manifests:{[operation]:{group:spec.group,name:spec.method,path:spec.path||'/synthetic-public-search',httpMethod:'GET',names:new Set(operation==='search'?['keyword','limit','offset']:['cursor','limit']),arrayFields:new Set()}}};
 class Command { async parseAsync() {readContext.captured=raw;readContext.outputCount=1;} }
 installReadCommandBoundary({Command});await new Command().parseAsync(['node','synthetic-cli']);
 return fixtureFinish({operation,call_id:'00000000-0000-0000-0000-000000000001'});
}};`)(require,path.dirname(srcPath));
const official=JSON.parse(fs.readFileSync(path.join(root,'tests/fixtures/music_aggregate_official_song_shape.json'),'utf8'));
const base=official.song,id=n=>n.toString(16).padStart(32,'0');
function song(n,artist='周杰伦',origin=1) {
 const s={...structuredClone(base),id:id(n),name:'晴天',artists:[],fullArtists:[{id:null,name:artist}],album:{id:id(999),name:'合成专辑'},originCoverType:origin};
 if(origin===null)delete s.originCoverType;return s;
}
async function pair(pub,cloud,total=pub.length) {
 return {public:await api.wire('search',{code:200,data:{records:pub,recordCount:total}}),
 cloud:await api.wire('cloud_songs',{code:200,data:{records:cloud,hasMore:false,total:cloud.length}})};
}
(async()=>{
 let groups=0;
 const officialWire=await pair([base],[]),m=officialWire.public.payload.songs[0].metadata;
 assert.deepEqual(m.artists,base.fullArtists.map(x=>x.name));assert.equal(m.album,base.album.name);
 assert.equal(m.recording_version,'original_performer');assert.equal(m.origin_cover_type,1);assert.equal(m.duration_ms,null);groups++;
 const ranked=await pair([song(1,'合成翻唱歌手',2)],[song(2)]);
 assert.equal(ranked.public.payload.songs[0].metadata.recording_version,'cover');
 assert.equal(ranked.cloud.payload.songs[0].metadata.recording_version,'original_performer');groups++;
 const unknown=song(3,null,null);unknown.fullArtists=null;unknown.artists=null;unknown.album=null;unknown.name='晴天（原版）';
 const unknownWire=await pair([],[unknown]);assert.deepEqual(unknownWire.cloud.payload.songs[0].metadata.unknown_fields,['artists','album','recording_version','duration_ms']);groups++;
 for(const value of [0,3,true,'1',null]) {
  const v=song(4,'周杰伦',value),r=await pair([],[v]);assert.equal(r.cloud.payload.songs[0].metadata.recording_version,null);
 }
 const incomplete=song(5);incomplete.fullArtists=[{name:'周杰伦'},{name:null}];incomplete.artists=[{name:'周杰伦'}];
 assert.equal((await pair([],[incomplete])).cloud.payload.songs[0].metadata.artists,null);groups++;
 const same=await pair([song(6)],[song(6)]);
 const pagination=await pair(Array.from({length:20},(_,i)=>song(1001+i,'周杰伦',null)),Array.from({length:50},(_,i)=>song(101+i,'周杰伦',null)),40);
 const publicNext=await api.wire('search',{code:200,data:{records:Array.from({length:20},(_,i)=>song(1021+i,'周杰伦',null)),recordCount:40}},20);
 assert.equal(pagination.public.payload.search_page.next_offset,20);assert.equal(publicNext.payload.search_page.next_offset,null);groups++;
 const beatlesPublic=[{...song(2001),name:'Provider candidate'},{...song(2002,'The Beatles'),name:'Come Together (Remastered)',album:{id:id(999),name:'Abbey Road (Remastered)'}}];
 const unrelated={...song(2003),name:'Other song',fullArtists:null,artists:null,album:null};
 const related={...song(2004),name:'Come Together',fullArtists:null,artists:null,album:null};
 const beatles=await pair(beatlesPublic,[unrelated,related]);
 const value={schema:1,beatles,provenance:official.source,live_provider_calls:0,groups,official:officialWire,ranked,unknown:unknownWire,same,pagination,public_next:publicNext};
 if(!process.argv[2])throw Error('output path required');fs.writeFileSync(process.argv[2],JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});
 console.log(JSON.stringify({status:'PASS',groups,production_projection:true,production_read_assembly:true,live_provider_calls:0,handcrafted_swift_metadata:false}));
})().catch(e=>{console.error(e);process.exitCode=1;});
