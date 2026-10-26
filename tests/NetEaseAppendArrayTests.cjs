'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const candidate=process.argv[2],runtime=process.argv[3],reports=[];
const minenv={PATH:'/usr/bin:/bin',TMPDIR:path.join(__dirname,'../build/source-migration-20261011'),LANG:'C',LC_ALL:'C'};
function run(args,input,env) {
 return new Promise((resolve,reject)=>{
  const child=cp.spawn(process.execPath,args,{env,stdio:['pipe','pipe','pipe']});
  let stdout='',stderrBytes=0,expired=false,exceeded=false,killer;
  const stop=()=>{child.kill('SIGTERM');killer??=setTimeout(()=>child.kill('SIGKILL'),500);};
  const timer=setTimeout(()=>{expired=true;stop();},12000);
  child.stdout.on('data',part=>{if(exceeded)return;stdout+=part;if(Buffer.byteLength(stdout)>524288){exceeded=true;stdout='';stop();}});
  child.stderr.on('data',part=>{stderrBytes+=part.length;if(stderrBytes>65536){exceeded=true;stop();}});
  child.stdin.on('error',()=>{});child.stdin.end(input);
  child.once('error',()=>{clearTimeout(timer);clearTimeout(killer);reject(Error('child_start'));});
  child.once('close',(code,signal)=>{clearTimeout(timer);clearTimeout(killer);resolve({code,signal,stdout,expired,exceeded,closed:true});});
 });
}
const baseline=process.argv[4]==='--baseline';
const allCases=baseline?[['append_array_body','playlist_append',true,-97011]]:[
 ['append_array_body','playlist_append',false],['append_array_map','playlist_append',false],
 ['append_array_location','playlist_append',false],['append_array_mixed','playlist_append',false],
 ['append_scalar_body','playlist_append',false],['append_scalar_get','playlist_append',false],
 ['create_scalar_get','playlist_create',false],
 ['append_array_query','playlist_append',false],['append_array_query_get','playlist_append',false],
 ['append_array_get_body','playlist_append',true,-97060],['append_playlist_array','playlist_append',true,-97059],
 ['create_array','playlist_create',true,-97059],['append_conflict_location','playlist_append',true,-97060],
 ['append_required_unknown','playlist_append',true,-97058],['append_map_mismatch','playlist_append',true,-97057],
 ['append_missing_song','playlist_append',true,-97061],
 ['append_tamper_extra','playlist_append',true,-97026],['append_tamper_wrong','playlist_append',true,-97026],
 ['append_tamper_scalar','playlist_append',true,-97026],['append_tamper_number','playlist_append',true,-97026],
 ['append_observed','playlist_append',false],['append_provider_rejected','playlist_append',false],['append_observed_noise','playlist_append',false],
 ['append_legacy_name','playlist_append',true,-97058],['append_wrong_route','playlist_append',true,-97055],
 ['append_query_wrong_song','playlist_append',true,-97026],['append_query_extra_songs','playlist_append',true,-97026]];
const focused=new Set(['append_observed','append_observed_noise','append_legacy_name','append_wrong_route','append_query_wrong_song','append_query_extra_songs']);
const cases=process.argv[4]==='--observed-contract-only'?allCases.filter(row=>focused.has(row[0])):
 process.argv[4]==='--faults-only'?allCases.filter(row=>row[0].startsWith('append_tamper_')):allCases;
async function main() {
 assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(runtime,'NetEase/dist/index.js'))).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');
 const id='00000000-0000-4000-8000-000000000001',key=crypto.createHash('sha256').update(id).digest();
 const pair=crypto.generateKeyPairSync('rsa',{modulusLength:2048,publicKeyEncoding:{type:'spki',format:'pem'},privateKeyEncoding:{type:'pkcs8',format:'pem'}});
 const encrypted=value=>{const iv=crypto.randomBytes(16),cipher=crypto.createCipheriv('aes-256-cbc',key,iv);return Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([cipher.update(JSON.stringify(value)),cipher.final()]).toString('hex')})).toString('base64');};
 const files={'.netease_mcp_device.json':Buffer.from(JSON.stringify({deviceId:id})).toString('base64'),'.config/ncm-cli/config.json':Buffer.from('{}').toString('base64'),
  '.config/ncm-cli/credentials.enc.json':encrypted({appId:'synthetic-application-only',privateKey:pair.privateKey}),
  '.config/ncm-cli/tokens.enc.json':encrypted({namedToken:'SYNTHETIC-NAMED-SESSION',namedRefreshToken:'SYNTHETIC-REFRESH',namedTokenExpireAt:Date.now()+3600000})};
 pair.privateKey='';key.fill(0);
 let credential=Buffer.from(JSON.stringify({schema:1,storage:'official',files})).toString('base64');
 for(const [name,operation,rejected,expectedRule] of cases) {
  const request={schema:1,operation,call_id:'00000000-0000-4000-8000-000000000002',credential,network_allowed:true,
   arguments:operation==='playlist_create'?{name:'Synthetic playlist'}:{playlist_id:'1'.repeat(32),song_id:'2'.repeat(32)}};
  if(name==='append_observed')request.business_audit=true;
  const result=await run(['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseAppendArrayMockLoader.mjs'),
   path.join(__dirname,'fixtures/NetEaseAppendArrayBridgeChild.cjs'),candidate,path.join(runtime,'Bridge')],JSON.stringify(request),{...minenv,ARL_SYNTHETIC_ARRAY_CASE:name});
  request.credential='';assert.equal(result.code,0);assert.equal(result.signal,null);assert.equal(result.expired,false);assert.equal(result.exceeded,false);
  const frames=result.stdout.trim().split('\n').filter(Boolean).map(row=>JSON.parse(row));result.stdout='';
  const complete=frames.filter(row=>row.event==='write_complete'),observed=frames.filter(row=>row.event==='synthetic_effect_observation');
  reports.push({case:name,state:complete[0]?.result?.state,effect_calls:observed[0]?.calls,rules:frames.filter(x=>x.code<=-97001&&x.code>=-97099).map(x=>x.code),tamper_count:observed[0]?.tamper_count,wire:observed[0]?.wire,child_closed:result.closed});
  assert.equal(complete.length,1);assert.equal(observed.length,1);
  assert.equal(complete[0].result.state,rejected?'not_submitted':name==='append_provider_rejected'?'outcome_unknown':'submitted');assert.equal(observed[0].calls,rejected?0:1);
  if(!rejected&&name!=='append_provider_rejected')assert.equal(complete[0].result.playlist_id,'1'.repeat(32));
  if(['append_observed','append_observed_noise','append_array_query','append_provider_rejected'].includes(name)) {
   assert.deepEqual(observed[0].wire,{post:true,url_query_empty:true,song_list_array:true,count:1,only_selected_song:true,playlist_unchanged:true,has_signature:true});
  }
  if(name==='append_observed') {
   const chunks=frames.filter(x=>x.event==='business_record'),records=[];
   for(const recordID of new Set(chunks.map(x=>x.record_id))) {
    const parts=chunks.filter(x=>x.record_id===recordID).sort((a,b)=>a.part-b.part);
    assert.equal(parts.length,parts[0].parts);parts.forEach((x,i)=>assert.equal(x.part,i));
    const bytes=Buffer.concat(parts.map(x=>Buffer.from(x.payload,'base64')));
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),parts[0].sha256);
    records.push(JSON.parse(bytes));
   }
   const sent=records.find(x=>x.event==='http_request'&&x.path==='/openapi/music/basic/playlist/song/batch/like');
   assert(sent);assert.equal(sent.method,'POST');assert.equal(sent.parameters.playlistId,'1'.repeat(32));
   assert.deepEqual(sent.parameters.songIdList,['2'.repeat(32)]);
   const reply=records.find(x=>x.event==='http_response'&&x.path===sent.path);
   assert(reply);assert.equal(reply.http_status,200);assert.equal(JSON.parse(reply.body_text).code,200);
   const saved=JSON.stringify(records);assert(!saved.includes('SYNTHETIC-NAMED-SESSION'));assert(!saved.includes('PRIVATE KEY'));
   const published=complete[0].result.provider_result;assert.equal(published.fields.body,undefined);assert.equal(published.fields.body_text,undefined);assert.equal(published.fields.business_text,undefined);assert.equal(published.fields.body_reference.complete,true);
   reports[reports.length-1].full_private_business_exchange_verified=true;
  }
  if(name==='append_provider_rejected') {
   const failure=frames.find(x=>x.phase==='effect'&&x.kind==='provider_rejected');
   assert.equal(failure?.provider_message,'songIdList: expected JSON array');assert.equal(failure?.provider_msg,'歌曲权限校验失败');
  }
  if(name.startsWith('append_tamper_')||name.startsWith('append_query_'))assert(observed[0].tamper_count>=1&&observed[0].tamper_count<=4);
  else assert.equal(observed[0].tamper_count,0);
  if(expectedRule)assert(frames.some(x=>x.code===expectedRule));
 }
 credential='';process.stdout.write(JSON.stringify({status:'PASS',baseline, cases:reports,official_pinned_CLI_executed:true,production_declared_method_business_and_HTTPS_gates_executed:true,real_network:0,real_credentials:0,direct_children_closed:cases.length})+'\n');
}
main().catch(()=>{process.stdout.write(JSON.stringify({status:'FAIL',reason:'synthetic_contract_assertion',cases:reports,raw_output_saved:false})+'\n');process.exitCode=1;});
