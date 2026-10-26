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
const cases=[{name:'bounded_small',operation:'search',state:'authorized_read'},{name:'bounded_large',operation:'search',state:'authorized_read'},{name:'formatter_expanded',operation:'search',state:'authorized_read'},{name:'numeric_expansion',operation:'search',state:'authorized_read'},{name:'provider_body_oversize',operation:'search',state:'contract_rejected',reason:'provider_response_invalid',stage:'provider_response'},{name:'business_rejection',operation:'search',state:'provider_rejected',reason:'provider_rejected',stage:'provider_response'},{name:'resource_missing',operation:'search',state:'provider_rejected',reason:'provider_resource_missing',stage:'provider_response'},{name:'bad_result',operation:'search',state:'contract_rejected',reason:'result_schema_invalid',stage:'projection'}];

async function main(){
 assert.equal(crypto.createHash('sha256').update(fs.readFileSync(cli)).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');

 const source=fs.readFileSync(candidate,'utf8'),start=source.indexOf('function projectionErrorShape('),end=source.indexOf('function recordProjectionErrorContext(',start);
 const scope=require('node:vm').createContext({object:v=>v!==null&&typeof v==='object'&&!Array.isArray(v),READ_CONTRACT_CODES:{ambiguous_result_array:-97030}});
 require('node:vm').runInContext(source.slice(start,end),scope);
 const two=scope.projectionErrorShape({data:{songs:[],list:[]}},'search',{code:'ambiguous_result_array'});
 assert.deepEqual(Array.from(two.q),[2,2,3]);assert.equal(two.a.length,2);
 const setup=source.slice(0,source.lastIndexOf('\ntry {\n  const request=readRequest();'));
 const api=new Function('require','__dirname',setup+'\nreturn {captureOutput,publicReadFailure,readFailure,projectRead,installNetworkBoundary,setContext(value){readContext=value;},context(){return readContext;}};')(require,path.dirname(candidate));
 const correlation='00000000-0000-4000-8000-000000000099';
 const context=(extras={})=>({isWrite:false,operation:'search',stage:'search',arguments:{keyword:'Synthetic'},failure:null,captured:null,outputCount:0,activeHTTPStatus:200,...extras});
 const overData=JSON.stringify({value:'x'.repeat(1048576)});api.setContext(context());api.captureOutput(overData);
 assert.equal(api.context().failure,null);assert.equal(api.context().captured.value.length,1048576); // HTTP is bounded before CLI capture.
 api.setContext(context());api.captureOutput('{');
 assert.equal(api.publicReadFailure('contract_rejected',correlation).reason,'cli_output_invalid');
 assert.equal(api.publicReadFailure('contract_rejected',correlation).local_code,-97001);
 api.setContext(context());api.captureOutput('{}');api.captureOutput('{}');
 assert.equal(api.publicReadFailure('contract_rejected',correlation).local_code,-97028);
 api.setContext(context({activeHTTPStatus:null}));api.readFailure('provider_unavailable');
 const network=api.publicReadFailure('provider_unavailable',correlation);assert.equal(network.http_status,null);assert.equal(network.retryable,true);assert.equal(network.automatic_retry,false);
 api.setContext(context({activeHTTPStatus:null}));api.readFailure('contract_rejected');
 const missing=api.publicReadFailure('contract_rejected',correlation);assert.equal(missing.reason,'runtime_output_missing');assert.equal(missing.http_status,null);assert.equal(missing.retryable,false);
 api.setContext(context({isWrite:true}));api.captureOutput(' '.repeat(65537));assert.equal(api.context().failure,null);assert.equal(api.context().outputCount,0);
 api.setContext(context());api.readFailure('contract_rejected',{reason:'SYNTHETIC-SECRET',stage:'SYNTHETIC-SECRET',httpStatus:0,localCode:123});
 assert.equal(JSON.stringify(api.publicReadFailure('contract_rejected',correlation)).includes('SYNTHETIC-SECRET'),false);
 const formattedLimit=1048576+(1048576+1)*(1+2*16);
 api.setContext(context());api.captureOutput(' '.repeat(formattedLimit+1));
 let failure=api.publicReadFailure('contract_rejected',correlation);assert.equal(failure.output_limit_bytes,formattedLimit);assert.equal(failure.output_bytes,formattedLimit+1);assert.equal(api.context().captured,null);
 for(const invalid of ['{"a":1 2}','{"a":t rue}','{"data":[1,2]','{"a":1,"a":2}']) {
  api.setContext(context());api.captureOutput(invalid);assert.equal(api.context().failure,'contract_rejected');assert.equal(api.context().captured,null);
 }
 api.setContext(context());api.captureOutput(JSON.stringify({text:'keep  whitespace\\and"quote',number:-1.2e3},null,2));
 assert.equal(api.context().captured.text,'keep  whitespace\\and"quote');assert.equal(api.context().captured.number,-1200);
 const https=require('node:https'),events=require('node:events'),prior=https.request;
 https.request=()=>{const request=new events.EventEmitter();request.setTimeout=()=>request;request.destroy=()=>{};return request;};
 api.setContext(context({activePath:'/openapi/music/basic/search/song/get/v2',activeMethod:'GET',consumeCount:0}));
 api.installNetworkBoundary(true);
 const request=https.request('https://openncm.music.163.com/openapi/music/basic/search/song/get/v2',{method:'GET'});
 const response=new events.EventEmitter();response.statusCode=200;response.destroy=()=>{};request.emit('response',response);response.emit('data',Buffer.alloc(1048577));
 failure=api.publicReadFailure('contract_rejected',correlation);assert.equal(failure.reason,'provider_response_invalid');assert.equal(failure.stage,'provider_response');assert.equal(failure.http_status,200);
 https.request=prior;
 const boundaryChecks=14;
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
  const result=await run(node,['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseReadOutputMockLoader.mjs'),
   path.join(__dirname,'fixtures/NetEaseSharedReadBridgeChild.cjs'),candidate,path.join(runtime,'Bridge')],JSON.stringify(request),
   {...minenv,ARL_SYNTHETIC_SHARED_CASE:fixture.name},12000);request.credential='';
  assert.equal(result.code,0);assert.equal(result.signal,null);assert.equal(result.expired,false);assert.equal(result.exceeded,false);
  const frames=result.stdout.trim().split('\n').filter(Boolean).map(row=>JSON.parse(row));result.stdout='';
  const diagnostics=frames.filter(row=>row.event==='diagnostic');diagnostics.forEach((row,i)=>assert.equal(row.sequence,i+1));
  assert.ok(diagnostics.length<=128);
  const observed=diagnostics.filter(row=>row.code<=-97100&&row.code>=-97120);
  const actual=observed.map(row=>[row.code,row.sub_code]);
  const rules=diagnostics.filter(row=>row.code<=-97001&&row.code>=-97050).map(row=>row.code);
  const sizes=diagnostics.filter(row=>[-97400,-97401].includes(row.code));assert.ok([0,2].includes(sizes.length));if(fixture.state==='authorized_read'||fixture.name==='bad_result')assert.equal(sizes.length,2);
  const outputBytes=sizes.length?sizes.find(row=>row.code===-97400).sub_code+1000000*sizes.find(row=>row.code===-97401).sub_code:null;if(outputBytes!==null)assert.ok(Number.isInteger(outputBytes)&&outputBytes>0);
  const completed=frames.filter(row=>row.event==='read_complete');
  const report={case:fixture.name,new_facts:actual,local_rule_codes:rules,wire_sequence_contiguous:true,
   read_complete_count:completed.length,read_state:completed[0]?.result?.state,child_closed:result.closed};reports.push(report);
  assert.equal(observed.length,fixture.operation==='user_playlists'?21:0);
  observed.forEach((row,i)=>{assert.equal(row.phase,'bridge');assert.equal(row.kind,'ignored');if(i)assert.equal(row.sequence,observed[i-1].sequence+1);});
  assert.equal(completed.length,1);assert.equal(completed[0].result.session,'present');
  assert.equal(completed.length,1);
  report.raw_cli_output_bytes=outputBytes;report.read_state=completed[0].result.state;report.projected_songs=completed[0].result.payload?.songs?.length??0;
  assert.equal(report.read_state,fixture.state);
  if(fixture.name==='formatter_expanded'){assert.equal(outputBytes,3127508);assert.equal(report.projected_songs,20);}
  if(fixture.reason){
    const f=completed[0].result.failure;assert.equal(f.reason,fixture.reason);assert.equal(f.stage,fixture.stage);assert.equal(f.correlation_id,callID);assert.equal(f.retryable,false);assert.equal(f.automatic_retry,false);assert.equal(f.http_status,200);
    assert.deepEqual(Object.keys(f).filter(k=>k!=='provider_status').sort(),['automatic_retry','correlation_id','http_status','local_code','next_step','output_bytes','output_limit_bytes','reason','retryable','stage']);if(f.provider_status){assert.equal(f.provider_status.classification,fixture.name==='resource_missing'?'resource_missing':'provider_rejection');if(fixture.name==='resource_missing'){assert.equal(f.provider_status.code,200);assert.equal(f.provider_status.sub_code,'10007');}assert.deepEqual(Object.keys(f.provider_status).sort(),['classification','code','sub_code']);assert.equal(typeof f.provider_status.code,'number');}report.failure=f;assert.equal(f.output_bytes,null);assert.equal(f.output_limit_bytes,null);assert.equal(f.next_step,fixture.state==='provider_rejected'?'inspect_provider_response':'inspect_adapter');
  }else{assert.equal(completed[0].result.failure,undefined);assert.equal(report.projected_songs,20);}
  report.synthetic_extra_text_leaked=JSON.stringify(completed[0].result).includes('SYNTHETIC-UNCONSUMED-');
  assert.equal(report.synthetic_extra_text_leaked,false);assert.equal(JSON.stringify(completed[0].result).includes('SYNTHETIC-PROVIDER-TEXT'),false);

 }
 credential='';
 process.stdout.write(JSON.stringify({status:'PASS',boundary_checks:boundaryChecks,cases:reports,official_pinned_CLI_executed:true,
  production_descriptor_and_fetch_and_HTTPS_gates_executed:true,native_logging_executed:false,real_network:0,real_credentials:0,raw_output_saved:false,
  direct_children_closed:cases.length})+'\n');
}
main().catch(error=>{process.stdout.write(JSON.stringify({status:'FAIL',reason:'synthetic_contract_assertion',failure_site:String(error?.stack||'').split('\n').find(line=>line.includes('NetEaseReadOutputBoundsTests.cjs:'))?.trim()||null,cases:reports,raw_output_saved:false})+'\n');process.exitCode=1;});
