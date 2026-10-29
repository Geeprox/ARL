// Decisive continuation regressions; real CLI, in-memory synthetic session,
// fixed mock routes and no real sockets. No native compiler or private state.
'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),cp=require('node:child_process');
const root=process.cwd(),runtime=process.argv[2],output=process.argv[3],bridge=path.join(root,'integrations/service_runtime/netease_bridge.cjs');
const source=fs.readFileSync(bridge,'utf8'),end=source.lastIndexOf('\ntry {\n  const request=readRequest();');
const api=new Function('require','__dirname',source.slice(0,end)+'\nreturn {collectMusicPages};')(require,path.dirname(bridge));
const env={PATH:'/usr/bin:/bin',TMPDIR:'/private/tmp',LANG:'C',LC_ALL:'C',ARL_SYNTHETIC_SHARED_CASE:'playlist_bounded_pages'};
function run(request){return new Promise((resolve,reject)=>{
 const p=cp.spawn(process.execPath,['--no-warnings','--experimental-loader',path.join(root,'tests/fixtures/NetEaseReadOutputMockLoader.mjs'),path.join(root,'tests/fixtures/NetEaseSharedReadBridgeChild.cjs'),bridge,path.join(runtime,'Bridge')],{cwd:root,env,stdio:['pipe','pipe','pipe']});
 let raw='',stderr=0,expired=false,overflow=false,killer;const stop=()=>{p.kill('SIGTERM');killer=setTimeout(()=>p.kill('SIGKILL'),500);};
 const timer=setTimeout(()=>{expired=true;stop();},15000);
 p.stdout.on('data',d=>{if(overflow)return;raw+=d;if(Buffer.byteLength(raw)>4*1024*1024){overflow=true;raw='';stop();}});
 p.stderr.on('data',d=>{stderr+=d.length;if(stderr>65536&&!overflow){overflow=true;stop();}});
 p.stdin.on('error',()=>{});p.stdin.end(JSON.stringify(request));
 p.once('error',reject);p.once('close',(code,signal)=>{clearTimeout(timer);clearTimeout(killer);try{assert.equal(code,0);assert.equal(signal,null);assert.equal(expired,false);assert.equal(overflow,false);const frames=raw.trim().split('\n').map(JSON.parse),done=frames.filter(x=>x.event==='read_complete');assert.equal(done.length,1);let result=done[0].result;
 if(result===undefined){
  const parts=frames.filter(x=>x.event==='read_result_part');assert(parts.length>0);
  for(const [i,part] of parts.entries()){assert.equal(part.part,i);assert.equal(part.parts,parts.length);assert.equal(part.sha256,done[0].result_sha256);assert.equal(part.call_id,request.call_id);assert(Buffer.from(part.payload,'base64').length<=65536);}
  const assembled=Buffer.concat(parts.map(x=>Buffer.from(x.payload,'base64')));
  assert.equal(crypto.createHash('sha256').update(assembled).digest('hex'),done[0].result_sha256);result=JSON.parse(assembled.toString('utf8'));assembled.fill(0);
 }
 for(const frame of frames)assert(Buffer.byteLength(JSON.stringify(frame))<=262144);
 const bytes=Math.max(...frames.map(frame=>Buffer.byteLength(JSON.stringify(frame))));raw='';resolve({result,private_frame_bytes:bytes,closed:true});}catch(e){reject(e);}});
 });}
function session(large=false){const id='00000000-0000-4000-8000-000000000081',key=crypto.createHash('sha256').update(id).digest();
 const encrypted=value=>{const iv=crypto.randomBytes(16),c=crypto.createCipheriv('aes-256-cbc',key,iv);return Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([c.update(JSON.stringify(value)),c.final()]).toString('hex')})).toString('base64');};
 const pair=crypto.generateKeyPairSync('rsa',{modulusLength:2048,publicKeyEncoding:{type:'spki',format:'pem'},privateKeyEncoding:{type:'pkcs8',format:'pem'}});
 const files={'.netease_mcp_device.json':Buffer.from(JSON.stringify({deviceId:id})).toString('base64'),'.config/ncm-cli/config.json':Buffer.from(JSON.stringify(large?{fixturePadding:'C'.repeat(60000)}:{})).toString('base64'),'.config/ncm-cli/credentials.enc.json':encrypted({appId:'SYNTHETIC-APP',privateKey:pair.privateKey}),'.config/ncm-cli/tokens.enc.json':encrypted({namedToken:'SYNTHETIC-SESSION',namedRefreshToken:'SYNTHETIC-REFRESH',namedTokenExpireAt:Date.now()+3600000,...(large?{fixturePadding:'T'.repeat(15000)}:{})})};
 pair.privateKey='';key.fill(0);return Buffer.from(JSON.stringify({schema:1,storage:'official',files})).toString('base64');}
let safeFailureStage="start",safeCounts={};
(async()=>{
 if(process.argv.includes('--large-envelope-only')){
   safeFailureStage='input_envelope';let credential=session(true);const envelopeBytes=Buffer.from(credential,'base64').length;safeCounts={envelope_bytes:envelopeBytes};assert.ok(envelopeBytes<=131072);
   const req={schema:1,operation:'playlist_detail',call_id:'00000000-0000-4000-8000-000000000084',credential,network_allowed:true,arguments:{playlist_id:'1'.repeat(32)}};
   safeFailureStage='first_read';const first=await run(req);safeCounts.state=first.result.state;
   safeCounts.failure_reason=first.result.failure?.reason;assert.equal(first.result.state,'authorized_read');
   const a=first.result.payload;assert.equal(a.songs.length,100);assert.equal(a.complete,true);
   assert.equal(a.pagination.state,'stable_observed');assert.equal(a.pagination.next_offset,null);
   req.arguments.offset='50';req.call_id='00000000-0000-4000-8000-000000000085';
   safeFailureStage='second_read';const second=await run(req);req.credential='';credential='';assert.equal(second.result.state,'authorized_read');
   const b=second.result.payload;assert.equal(b.pagination.offset,50);assert.equal(b.pagination.next_offset,null);assert.equal(b.complete,false);
   assert.equal(b.pagination.state,'continuation_end');
   const ids=a.songs.map(x=>x.song_id);assert.equal(ids.length,100);assert.equal(new Set(ids).size,100);
   assert.deepEqual(b.songs.map(x=>x.song_id),ids.slice(50));
   for(const v of [first,second])assert.ok(v.private_frame_bytes+1<=262144);
   const file=path.join(output,'MUSIC-PAGINATION-PUBLIC-FIXTURE.json'),publicFixture=JSON.parse(fs.readFileSync(file,'utf8'));
   publicFixture.large_first=first.result;publicFixture.large_second=second.result;fs.writeFileSync(file,JSON.stringify(publicFixture));
   process.stdout.write(JSON.stringify({status:'PASS',counterexample:'large_envelope_uses_parts_without_truncating_snapshot',envelope_bytes:envelopeBytes,private_frame_bytes:[first.private_frame_bytes,second.private_frame_bytes],unchanged_line_limit:262144,page_counts:[a.songs.length,b.songs.length],all_unique_ids:ids.length,whole_playlist_complete:true,child_processes_closed:2,real_network:0,real_credentials:0,native_executed:false})+'\n');return;
 }

 const simple=[{song_id:'1'.repeat(32),name:'One'}];let calls=0;
 const full=await api.collectMusicPages(async()=>{calls++;return {items:simple,total:1,hasMore:false};},{kind:'song',pageSize:100});
 assert.equal(calls,2);assert.equal(full.complete,true);assert.equal(full.pagination.state,'stable_observed');
 let driftCalls=0;const drift=await api.collectMusicPages(async()=>({items:[{song_id:'1'.repeat(32),name:++driftCalls===1?'Before':'After'}],total:1,hasMore:false}),{kind:'song',pageSize:100});assert.equal(drift.complete,false);assert.equal(drift.pagination.state,'drift');
 let credential=session();const req={schema:1,operation:'playlist_detail',call_id:'00000000-0000-4000-8000-000000000082',credential,network_allowed:true,arguments:{playlist_id:'1'.repeat(32)}};
 const first=await run(req);assert.equal(first.result.state,'authorized_read');const a=first.result.payload;
 assert.equal(a.songs.length,100);assert.equal(a.complete,true);assert.equal(a.pagination.next_offset,null);assert.equal(a.pagination.offset,0);assert.equal(a.pagination.state,'stable_observed');
 assert.ok(Buffer.byteLength(JSON.stringify(a.songs))>98304);
 const next=50;req.arguments.offset=String(next);req.call_id='00000000-0000-4000-8000-000000000083';
 const second=await run(req);req.credential='';credential='';assert.equal(second.result.state,'authorized_read');const b=second.result.payload;
 assert.equal(b.pagination.offset,next);assert.equal(b.pagination.next_offset,null);assert.equal(b.pagination.state,'continuation_end');assert.equal(b.complete,false);
 const ids=a.songs.map(x=>x.song_id);assert.equal(ids.length,100);assert.equal(new Set(ids).size,100);
 assert.deepEqual(b.songs.map(x=>x.song_id),ids.slice(next));
 fs.writeFileSync(path.join(output,'MUSIC-PAGINATION-PUBLIC-FIXTURE.json'),JSON.stringify({first:first.result,second:second.result}));
 const result={status:'PASS',before_first_page_count:0,after_page_counts:[a.songs.length,b.songs.length],offsets:[a.pagination.offset,b.pagination.offset],all_unique_ids:ids.length,whole_playlist_complete:true,small_zero_offset_stable_complete:true,drift_still_incomplete:true,private_frame_bytes:[first.private_frame_bytes,second.private_frame_bytes],child_processes_closed:2,real_network:0,real_credentials:0,native_executed:false};
 process.stdout.write(JSON.stringify(result)+'\n');
})().catch(()=>{process.stdout.write(JSON.stringify({status:'FAIL',stage:safeFailureStage,counts:safeCounts,raw_private_output_saved:false})+'\n');process.exitCode=1;});
