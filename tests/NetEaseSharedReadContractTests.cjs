'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const node=process.execPath,candidate=process.argv[2],runtime=process.argv[3];
const cli=path.join(runtime,'NetEase/dist/index.js'),reports=[];
const minenv={PATH:'/usr/bin:/bin',TMPDIR:'/tmp',LANG:'C',LC_ALL:'C',PYTHONDONTWRITEBYTECODE:'1'};
function run(exe,args,input,env,timeout) {
 return new Promise((resolve,reject)=>{
  const child=cp.spawn(exe,args,{env,stdio:['pipe','pipe','pipe']});
  let stdout='',stderrBytes=0,expired=false,exceeded=false,killer=null;
  const stop=()=>{child.kill('SIGTERM');if(!killer)killer=setTimeout(()=>child.kill('SIGKILL'),500);};
  const timer=setTimeout(()=>{expired=true;stop();},timeout);
  child.stdout.on('data',part=>{if(exceeded)return;stdout+=part;if(Buffer.byteLength(stdout)>524288){exceeded=true;stdout='';stop();}});
  child.stderr.on('data',part=>{stderrBytes+=part.length;if(stderrBytes>65536){exceeded=true;stop();}});
  child.stdin.on('error',()=>{});child.stdin.end(input);
  child.once('error',()=>{clearTimeout(timer);clearTimeout(killer);reject(Error('synthetic_child_start'));});
  child.once('close',(code,signal)=>{clearTimeout(timer);clearTimeout(killer);resolve({code,signal,stdout,stderrBytes,expired,exceeded,closed:true});});
 });
}
const cases=[
 {name:'created_extended',operation:'user_playlists'},
 {name:'search_extended',operation:'search'},
 {name:'detail_extended',operation:'playlist_detail'},
 {name:'search_wrong_method',operation:'search',rule:-97010},
 {name:'search_wrong_auth',operation:'search',rule:-97010},
 {name:'detail_wrong_route',operation:'playlist_detail',rule:-97010},
 {name:'search_unknown_required',operation:'search',rule:-97011},
 {name:'detail_dependent_call',operation:'playlist_detail',rule:-97011},
 {name:'search_preprocess',operation:'search',rule:-97009},
 {name:'search_bad_location',operation:'search',rule:-97011},
 {name:'search_duplicate',operation:'search',rule:-97011},
 {name:'detail_duplicate_command',operation:'playlist_detail',rule:-97008}
];
async function main(){
 assert.equal(crypto.createHash('sha256').update(fs.readFileSync(cli)).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');

 const id='00000000-0000-4000-8000-000000000001',key=crypto.createHash('sha256').update(id).digest();
 function encrypted(value){const iv=crypto.randomBytes(16),cipher=crypto.createCipheriv('aes-256-cbc',key,iv);return Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([cipher.update(JSON.stringify(value)),cipher.final()]).toString('hex')})).toString('base64');}
 const pair=crypto.generateKeyPairSync('rsa',{modulusLength:2048,publicKeyEncoding:{type:'spki',format:'pem'},privateKeyEncoding:{type:'pkcs8',format:'pem'}});
 const files={'.netease_mcp_device.json':Buffer.from(JSON.stringify({deviceId:id})).toString('base64'),
  '.config/ncm-cli/config.json':Buffer.from('{}').toString('base64'),
  '.config/ncm-cli/credentials.enc.json':encrypted({appId:'synthetic-application-only',privateKey:pair.privateKey}),
  '.config/ncm-cli/tokens.enc.json':encrypted({namedToken:'SYNTHETIC-NAMED-SESSION',namedRefreshToken:'SYNTHETIC-REFRESH',namedTokenExpireAt:Date.now()+3600000})};
 pair.privateKey='';key.fill(0);
 let credential=Buffer.from(JSON.stringify({schema:1,storage:'official',files})).toString('base64');
 for(const fixture of cases){
  const callID='00000000-0000-4000-8000-000000000002';
  const request={schema:1,operation:fixture.operation,call_id:callID,credential,network_allowed:true,arguments:fixture.operation==='search'?{keyword:'Synthetic query'}:fixture.operation==='playlist_detail'?{playlist_id:'1'.repeat(32)}:{}};
  const result=await run(node,['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseSharedReadMockLoader.mjs'),
   path.join(__dirname,'fixtures/NetEaseSharedReadBridgeChild.cjs'),candidate,path.join(runtime,'Bridge')],JSON.stringify(request),
   {...minenv,ARL_SYNTHETIC_SHARED_CASE:fixture.name},12000);request.credential='';
  assert.equal(result.code,0);assert.equal(result.signal,null);assert.equal(result.expired,false);assert.equal(result.exceeded,false);
  const frames=result.stdout.trim().split('\n').filter(Boolean).map(row=>JSON.parse(row));result.stdout='';
  const diagnostics=frames.filter(row=>row.event==='diagnostic');diagnostics.forEach((row,i)=>assert.equal(row.sequence,i+1));
  assert.ok(diagnostics.length<=128);
  const observed=diagnostics.filter(row=>row.code<=-97100&&row.code>=-97120);
  const actual=observed.map(row=>[row.code,row.sub_code]);
  const rules=diagnostics.filter(row=>row.code<=-97001&&row.code>=-97050).map(row=>row.code);
  const completed=frames.filter(row=>row.event==='read_complete');
  const report={case:fixture.name,new_facts:actual,local_rule_codes:rules,wire_sequence_contiguous:true,
   read_complete_count:completed.length,read_state:completed[0]?.result?.state,child_closed:result.closed};reports.push(report);
  assert.equal(observed.length,fixture.operation==='user_playlists'?21:0);
  observed.forEach((row,i)=>{assert.equal(row.phase,'bridge');assert.equal(row.kind,'ignored');if(i)assert.equal(row.sequence,observed[i-1].sequence+1);});
  assert.equal(completed.length,1);assert.equal(completed[0].result.session,'present');
  assert.equal(completed[0].result.state,fixture.rule?'contract_rejected':'authorized_read');
  assert.deepEqual(rules,fixture.rule?[-97017,fixture.rule]:[-97017]);
  if(!fixture.rule){const payload=completed[0].result.payload;assert.equal(payload.complete,true);assert.equal((payload.playlists||payload.songs).length,1);if(fixture.operation==='playlist_detail')assert.equal(payload.playlist.playlist_id,'1'.repeat(32));}

 }
 credential='';
 process.stdout.write(JSON.stringify({status:'PASS',cases:reports,official_pinned_CLI_executed:true,
  production_descriptor_and_fetch_and_HTTPS_gates_executed:true,native_logging_executed:false,real_network:0,real_credentials:0,raw_output_saved:false,
  direct_children_closed:cases.length})+'\n');
}
main().catch(()=>{process.stdout.write(JSON.stringify({status:'FAIL',reason:'synthetic_contract_assertion',cases:reports,raw_output_saved:false})+'\n');process.exitCode=1;});
