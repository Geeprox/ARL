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
const cases=[{name:'search_records_shape',operation:'search'},{name:'search_records_ambiguous',operation:'search',rule:-97030},{name:'search_records_wrong_type',operation:'search',rule:-97031}];

async function main(){
 assert.equal(crypto.createHash('sha256').update(fs.readFileSync(cli)).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');

 const source=fs.readFileSync(candidate,'utf8'),start=source.indexOf('function projectionErrorShape('),end=source.indexOf('function recordProjectionErrorContext(',start);
 const scope=require('node:vm').createContext({object:v=>v!==null&&typeof v==='object'&&!Array.isArray(v),READ_CONTRACT_CODES:{ambiguous_result_array:-97030}});
 require('node:vm').runInContext(source.slice(start,end),scope);
 const two=scope.projectionErrorShape({data:{songs:[],list:[]}},'search',{code:'ambiguous_result_array'});
 assert.deepEqual(Array.from(two.q),[2,2,3]);assert.equal(two.a.length,2);
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
  const result=await run(node,['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseSearchRecordsMockLoader.mjs'),
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
  const headers=diagnostics.filter(row=>row.code===-97200);
  assert.equal(headers.length,fixture.rule?1:0);
  if(fixture.rule){
   const length=diagnostics.find(row=>row.code===-97201).sub_code;assert.ok(length>0&&length<=224);
   const chunks=diagnostics.filter(row=>row.code<=-97300&&row.code>=-97395);
   assert.equal(chunks.length,Math.ceil(length*8/19));let accumulator=0,bits=0,bytes=[];
   chunks.forEach((row,i)=>{assert.equal(row.code,-97300-i);assert.ok(Number.isInteger(row.sub_code)&&row.sub_code>=0&&row.sub_code<2**19);accumulator=accumulator*2**19+row.sub_code;bits+=19;while(bits>=8){bits-=8;const scale=2**bits;bytes.push(Math.floor(accumulator/scale));accumulator%=scale;}});
   const shape=JSON.parse(require('node:zlib').inflateRawSync(Buffer.from(bytes.slice(0,length)),{maxOutputLength:32768}));
   assert.equal(shape.s,1);assert.equal(shape.r,fixture.rule);assert.deepEqual(shape.q,fixture.rule===-97030?[2,2,5]:[1,0,4]);
   assert.ok(!/DO-NOT-LEAK|Synthetic song|Synthetic artist|111111|222222|token|account/.test(JSON.stringify(shape)));
   report.projection_shape=shape;report.projection_packet=[...headers,diagnostics.find(row=>row.code===-97201),...chunks].map(({code,sub_code})=>({code,sub_code}));
  }

  if(!fixture.rule){
   const payload=completed[0].result.payload;
   assert.equal(payload.complete,false);assert.equal(payload.songs.length,20);
   assert.deepEqual(payload.search_page,{offset:0,limit:20,total:21,continuation_supported:true,next_offset:20});
   const expected=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/NetEaseSearchRecordsShape.json'))).data.records;
   payload.songs.forEach((song,i)=>{
    assert.equal(song.song_id,expected[i].encryptedId);assert.equal(song.name,expected[i].name);
    assert.equal(song.url,'https://music.163.com/#/song?id='+expected[i].originalId);assert.equal(song.visible,true);
    const legacy={...song.metadata};delete legacy.business_info;
    assert.deepEqual(legacy,{artists:['Synthetic artist'],album:'Synthetic album',recording_version:null,origin_cover_type:null,duration_ms:null,unknown_fields:['recording_version','duration_ms']});
    assert.equal(song.metadata.business_info.duration_unit,null);assert.equal(song.metadata.business_info.recording_edition,null);
   });
   report.projected_songs=20;report.total=21;report.item_mapping_validated_on_synthetic_fields=true;
  }

 }
 credential='';
 process.stdout.write(JSON.stringify({status:'PASS',cases:reports,official_pinned_CLI_executed:true,
  production_descriptor_and_fetch_and_HTTPS_gates_executed:true,native_logging_executed:false,real_network:0,real_credentials:0,raw_output_saved:false,
  direct_children_closed:cases.length})+'\n');
}
main().catch(()=>{process.stdout.write(JSON.stringify({status:'FAIL',reason:'synthetic_contract_assertion',cases:reports,raw_output_saved:false})+'\n');process.exitCode=1;});
