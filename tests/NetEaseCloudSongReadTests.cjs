'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const srcPath=path.resolve(process.argv[2]||'integrations/service_runtime/netease_bridge.cjs');
const src=fs.readFileSync(srcPath,'utf8'),setup=src.slice(0,src.lastIndexOf('\ntry {\n  const request=readRequest();'));
const api=new Function('require','__dirname',setup+'\nreturn {validateCloudSongDescriptor,projectReadManifestReply,validateManifests,projectCloudSongs,installReadCommandBoundary,set(c){readContext=c;},capture(r){readContext.captured=r;readContext.outputCount=1;},session(){inspectSession=()=>({present:true});},secret(v){privatePatterns.add(v);},clear(){privatePatterns.clear();}};')(require,path.dirname(srcPath));
const endpoint='/openapi/music/cloud/song/list/cursor/get';
const descriptor=()=>({name:'list',path:endpoint,http_method:'GET',auth_required:true,parameters:[
 {name:'cursor',type:'string',in:'query',required:false},{name:'sortType',type:'string',in:'query',required:false},
 {name:'limit',type:'number',in:'query',required:false}]});
const manifest=()=>({manifests:{root:{methods:[],sub_resources:[{name:'cloud',path:'c'}]},c:{methods:[descriptor()],sub_resources:[]}}});
const song=(id='1'.repeat(32))=>({id,name:'Synthetic title',artists:[{name:'Expected Artist'}],album:'Expected Album',privateCloudSong:true,playFlag:false});
const reply=()=>({code:200,data:{songs:[song()],hasMore:true,cursor:'cursor-next',total:60}});
let groups=0;const group=f=>{f();groups++;};
api.set({operation:'cloud_songs',isWrite:false,arguments:{}});
group(()=>{api.validateCloudSongDescriptor(descriptor());const p=api.projectReadManifestReply(manifest()),v=api.validateManifests(p);assert.equal(v.cloud_songs.path,endpoint);assert.deepEqual([...v.cloud_songs.names].sort(),['cursor','limit']);});
group(()=>{for(const mutation of [m=>m.path='/openapi/music/cloud/file/list',m=>m.http_method='POST',m=>m.auth_required=false,m=>m.parameters[2].type='string',m=>m.parameters[0].required=true,m=>m.parameters[0].in='body']){const m=descriptor();mutation(m);assert.throws(()=>api.validateCloudSongDescriptor(m));}});
group(()=>{const m=manifest();m.manifests.c.methods.push(descriptor());assert.throws(()=>api.projectReadManifestReply(m));m.manifests.c.methods=[];assert.throws(()=>api.projectReadManifestReply(m));});
group(()=>{const m=manifest();m.manifests.c.methods[0].parameters[0].default='NEVER_FORWARD';m.manifests.c.methods[0].fixed_params={sortType:'NEVER_GUESS'};const p=api.projectReadManifestReply(m);assert.ok(!JSON.stringify(p).includes('NEVER_'));assert.ok(!p.manifests.c.methods[0].parameters.some(p=>p.name==='sortType'));});
group(()=>{const v=api.projectCloudSongs(reply());assert.equal(v.songs[0].song_id,'1'.repeat(32));assert.equal(v.songs[0].private_cloud_song,true);assert.equal(v.songs[0].play_flag,false);assert.equal(v.cloud_page.next_cursor,'cursor-next');assert.equal(v.complete,false);});
group(()=>{const r=reply();r.data.songs=[{id:'2'.repeat(32),name:'Synthetic title',artists:null,album:''}];const v=api.projectCloudSongs(r);assert.deepEqual(v.songs[0].metadata.unknown_fields,['artists','album','recording_version','duration_ms']);assert.ok(!Object.hasOwn(v.songs[0],'private_cloud_song'));});
group(()=>{const r=reply();r.data.songs.push(song());assert.throws(()=>api.projectCloudSongs(r));r.data.songs=[song('not-an-encrypted-id')];assert.throws(()=>api.projectCloudSongs(r));});
group(()=>{const r=reply();r.data.songs=Array.from({length:51},(_,i)=>song(i.toString(16).padStart(32,'0')));assert.throws(()=>api.projectCloudSongs(r));});
group(()=>{for(const cursor of ['-option','bad\ncursor','x'.repeat(1025)]){const r=reply();r.data.cursor=cursor;assert.throws(()=>api.projectCloudSongs(r));}api.set({operation:'cloud_songs',isWrite:false,arguments:{cursor:'cursor-next'}});assert.throws(()=>api.projectCloudSongs(reply()));api.set({operation:'cloud_songs',isWrite:false,arguments:{}});});
group(()=>{const r=reply();delete r.data.hasMore;const v=api.projectCloudSongs(r);assert.equal(v.complete,false);assert.equal(v.cloud_page.has_more,null);r.data.hasMore=false;assert.equal(api.projectCloudSongs(r).cloud_page.next_cursor,null);});
group(()=>{api.secret('cursor-next');assert.throws(()=>api.projectCloudSongs(reply()));api.clear();});
(async()=>{
 const context={pageDeadline:Infinity,consumeCount:0,operation:'cloud_songs',isWrite:false,arguments:{},results:{},manifests:api.validateManifests(api.projectReadManifestReply(manifest()))};
 api.set(context);api.session();let seen;
 class Command {async parseAsync(argv){seen=argv;api.capture(reply());}}
 api.installReadCommandBoundary({Command});await new Command().parseAsync(['node','official-cli']);
 assert.deepEqual(seen.slice(2,6),['cloud','list','--limit','50']);
 assert.ok(!seen.includes('--sortType')&&!seen.includes('--cursor'));
 assert.equal(context.results.cloud_songs.cloud_page.next_cursor,'cursor-next');groups++;
 // A legal rich provider page is re-requested at the same cursor with a smaller
 // limit. Every returned row is complete; the provider cursor covers exactly it.
 const rich=Array.from({length:50},(_,i)=>({...song((i+1).toString(16).padStart(32,'0')),name:'Synthetic '+i,
   fullArtists:Array.from({length:20},(_,n)=>({id:(100+n).toString(16).padStart(32,'0'),name:'a'.repeat(200)})),
   album:{id:'b'.repeat(32),name:'b'.repeat(400)},duration:240000}));
 const cursors=[],limits=[],ids=[];let cursor=null,requestedLimit=50,rounds=0;
 do {
  const c={pageDeadline:Infinity,consumeCount:0,operation:'cloud_songs',isWrite:false,arguments:{limit:String(requestedLimit),...(cursor?{cursor}:{})},results:{},manifests:api.validateManifests(api.projectReadManifestReply(manifest()))};
  api.set(c);const attempts=[];
  class RichCommand {async parseAsync(argv){const limit=Number(argv[argv.indexOf('--limit')+1]),arg=argv.includes('--cursor')?argv[argv.indexOf('--cursor')+1]:null;attempts.push(arg);limits.push(limit);
   const start=arg===null?0:Number(arg.slice(5)),rows=rich.slice(start,start+limit),next=start+rows.length;
   api.capture({code:200,data:{records:rows,hasMore:next<rich.length,nextCursor:next<rich.length?'page-'+next:null,total:rich.length}});
  }}
  api.installReadCommandBoundary({Command:RichCommand});await new RichCommand().parseAsync(['node','official-cli']);
  assert.ok(attempts.every(v=>v===cursor));const result=c.results.cloud_songs;assert.ok(Buffer.byteLength(JSON.stringify(result))<262144);
  for(const row of result.songs){assert.equal(row.provider_record.fields.fullArtists.length,20);assert.equal(row.provider_record.fields.fullArtists[19].name,'a'.repeat(200));ids.push(row.song_id);}
  requestedLimit=result.cloud_page.limit;cursor=result.cloud_page.next_cursor;cursors.push(cursor);assert.ok(++rounds<20);
 }while(cursor!==null);
 assert.ok(limits.includes(50)&&limits.some(n=>n<50));assert.equal(ids.length,50);assert.equal(new Set(ids).size,50);groups++;
 console.log(JSON.stringify({status:'PASS',groups,provider_calls:0,credential_access:0,unknown_operations:0}));
})().catch(error=>{console.error(error);process.exitCode=1;});
