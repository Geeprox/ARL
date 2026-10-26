'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const node=process.execPath,candidate=process.argv[2],runtime=process.argv[3],collector=process.argv[4];
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
const facts=values=>values.map((value,i)=>[-97100-i,value]);
const cases=[
 {name:'valid',values:[3,0,1,0,2,2,2,0,1,1,0,0,0,0,0,0,0,0,0,0,0]},
 {name:'multi',fault:-97010,values:[3,68,2,2,2,2,2,30,1,1,0,0,0,1,1,1,1,1,0,0,0]},
 {name:'unknown',fault:-97010,values:[3,324,2,6,2,2,2,1310,1,1,0,0,0,1,1,1,1,1,1,0,0]},
 {name:'latent',fault:-97011,values:[3,0,1,2,2,2,2,30,1,1,0,0,0,1,1,1,1,1,0,0,0]},
 {name:'tail',fault:-97010,values:[3,16,1,0,2,6,6,98,3,2,1,3,0,1,0,0,0,4,0,0,0]},
 {name:'map',fault:-97010,values:[3,24,1,0,3,2,2,0,1,1,0,0,0,0,0,0,0,0,0,0,0]},
 {name:'map_fault',fault:-97010,values:[3,24,1,0,3,2,2,30,1,1,0,0,0,1,1,1,1,1,0,0,0]},
 {name:'falsy',values:[3,0,1,3,2,2,2,0,1,1,0,0,0,0,0,0,0,0,0,0,0]}
];
async function main(){
 assert.equal(crypto.createHash('sha256').update(fs.readFileSync(cli)).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');
 assert.ok(collector);
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
  const request={schema:1,operation:'user_playlists',call_id:callID,credential,network_allowed:true,arguments:{}};
  const result=await run(node,['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseCreatedManifestMockLoader.mjs'),
   path.join(__dirname,'fixtures/NetEaseCreatedManifestBridgeChild.cjs'),candidate,path.join(runtime,'Bridge')],JSON.stringify(request),
   {...minenv,ARL_SYNTHETIC_CREATED_CASE:fixture.name},12000);request.credential='';
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
  assert.deepEqual(actual,facts(fixture.values));assert.equal(observed.length,21);
  observed.forEach((row,i)=>{assert.equal(row.phase,'bridge');assert.equal(row.kind,'ignored');if(i)assert.equal(row.sequence,observed[i-1].sequence+1);});
  assert.equal(completed.length,1);assert.equal(completed[0].result.session,'present');
  assert.equal(completed[0].result.state,fixture.fault?'contract_rejected':'authorized_read');
  assert.deepEqual(rules,fixture.fault?[-97017,fixture.fault]:[-97017]);
  if(!fixture.fault){assert.equal(completed[0].result.payload.complete,true);assert.equal(completed[0].result.payload.playlists.length,1);}
  // Exercise exactly the future log readback decoder, with native field names.
  const rows=diagnostics.filter(row=>row.phase==='bridge'&&row.kind==='ignored'&&row.code<=-97001&&row.code>=-97120).map(row=>({processID:42,
   eventMessage:'netease_diagnostic_v1 '+JSON.stringify({callID:row.call_id,phase:row.phase,kind:row.kind,code:row.code,subCode:row.sub_code,
    httpStatus:row.http_status,providerStatus:row.provider_status,elapsedMS:row.elapsed_ms})}));
  const readback=await run('/usr/bin/python3',[collector,'--synthetic'],JSON.stringify({call_id:callID,pid:42,rows}),minenv,5000);
  assert.equal(readback.code,0);assert.equal(readback.signal,null);assert.equal(readback.expired,false);assert.equal(readback.exceeded,false);
  const consumed=JSON.parse(readback.stdout);readback.stdout='';
  assert.equal(consumed.series_complete,true);assert.equal(consumed.descriptor_scan_complete,true);
  assert.deepEqual(consumed.facts,actual);assert.deepEqual(consumed.local_rule_codes,rules);
  assert.equal(consumed.last_local_rule_code,fixture.fault??-97017);
  assert.equal(consumed.descriptor_predicates_all_pass,!fixture.fault);
  report.readback_exact_facts_and_terminal_rule=true;report.readback_child_closed=readback.closed;
 }
 credential='';
 process.stdout.write(JSON.stringify({status:'PASS',cases:reports,official_pinned_CLI_executed:true,
  same_readback_parser_consumed:true,native_logging_executed:false,real_network:0,real_credentials:0,raw_output_saved:false,
  direct_children_closed:cases.length*2})+'\n');
}
main().catch(()=>{process.stdout.write(JSON.stringify({status:'FAIL',reason:'synthetic_contract_assertion',cases:reports,raw_output_saved:false})+'\n');process.exitCode=1;});
