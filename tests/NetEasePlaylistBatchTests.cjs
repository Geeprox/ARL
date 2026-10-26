'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const candidate=process.argv[2],runtime=process.argv[3];
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(runtime,'NetEase/dist/index.js'))).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');
const id='00000000-0000-4000-8000-000000000001',key=crypto.createHash('sha256').update(id).digest();
const pair=crypto.generateKeyPairSync('rsa',{modulusLength:2048,privateKeyEncoding:{type:'pkcs8',format:'pem'},publicKeyEncoding:{type:'spki',format:'pem'}});
function enc(value){const iv=crypto.randomBytes(16),c=crypto.createCipheriv('aes-256-cbc',key,iv);return Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([c.update(JSON.stringify(value)),c.final()]).toString('hex')})).toString('base64');}
const files={'.netease_mcp_device.json':Buffer.from(JSON.stringify({deviceId:id})).toString('base64'),'.config/ncm-cli/config.json':Buffer.from('{}').toString('base64'),'.config/ncm-cli/credentials.enc.json':enc({appId:'SYNTHETIC-METADATA',privateKey:pair.privateKey}),'.config/ncm-cli/tokens.enc.json':enc({namedToken:'SYNTHETIC-SESSION',namedRefreshToken:'SYNTHETIC-REFRESH',namedTokenExpireAt:Date.now()+3600000})};
pair.privateKey='';key.fill(0);let credential=Buffer.from(JSON.stringify({schema:1,storage:'official',files})).toString('base64');
const contracts=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/NetEasePlaylistBatchContracts.json'))).methods;
const reports=[];
for(const [operation,method] of [['playlist_update_tags','updateTags'],['playlist_add_songs','add'],['playlist_reorder','reorder'],['playlist_remove_songs','remove']]){
 for(const scenario of ['success','wrong_method','wrong_path','wrong_auth','wrong_location','wrong_type','extra_required','provider400','lost_after_effect']){
  const args={playlist_id:'1'.repeat(32),[method==='updateTags'?'tags':'song_ids']:JSON.stringify(method==='updateTags'?['流行','摇滚']:Array.from({length:500},(_,i)=>(i+1).toString(16).padStart(32,'0')))};
  const input={schema:1,operation,call_id:'00000000-0000-4000-8000-000000000002',credential,network_allowed:true,arguments:args};
  const p=cp.spawnSync(process.execPath,['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEasePlaylistBatchLoader.mjs'),path.join(__dirname,'fixtures/NetEasePlaylistBatchChild.cjs'),candidate,path.join(runtime,'Bridge')],{input:JSON.stringify(input),env:{PATH:'/usr/bin:/bin',TMPDIR:'/tmp',LANG:'C',ARL_METADATA_CASE:scenario,ARL_METADATA_ARGS:JSON.stringify(args),ARL_BATCH_SPEC:JSON.stringify(contracts[method])},encoding:'utf8',timeout:20000,maxBuffer:2097152});
  assert.equal(p.status,0,JSON.stringify({operation,scenario,stderr:p.stderr?.slice(-1000)}));
  const frames=p.stdout.trim().split('\n').map(s=>JSON.parse(s));p.stdout='';
  const observed=frames.find(x=>x.event==='synthetic_effect_observation'),end=frames.find(x=>x.event==='write_complete');
  const expectedCalls=['success','provider400','lost_after_effect'].includes(scenario)?1:0;
  assert.equal(observed?.calls,expectedCalls,JSON.stringify({operation,scenario,observed,end,errors:frames.filter(x=>['error','diagnostic'].includes(x.event))}));
  assert.equal(end?.result.state,scenario==='success'?'submitted':['provider400','lost_after_effect'].includes(scenario)?'outcome_unknown':'not_submitted',JSON.stringify({operation,scenario,end,frames}));
  reports.push({operation,scenario,effect_calls:observed.calls,state:end.result.state,items:method==='updateTags'?2:500});
 }
}
credential='';console.log(JSON.stringify({status:'PASS',cases:reports,official_pinned_CLI:true,real_network:0,real_credentials:0}));
