'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),cp=require('node:child_process');
const bridge=process.argv[2],runtime=process.argv[3],output=process.argv[4],reports=[];
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(runtime,'NetEase/dist/index.js'))).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');
const id='00000000-0000-4000-8000-000000000001',key=crypto.createHash('sha256').update(id).digest();
const encrypted=value=>{const iv=crypto.randomBytes(16),c=crypto.createCipheriv('aes-256-cbc',key,iv);return Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([c.update(JSON.stringify(value)),c.final()]).toString('hex')})).toString('base64');};
const pair=crypto.generateKeyPairSync('rsa',{modulusLength:2048,privateKeyEncoding:{type:'pkcs8',format:'pem'},publicKeyEncoding:{type:'spki',format:'pem'}});
const files={'.netease_mcp_device.json':Buffer.from(JSON.stringify({deviceId:id})).toString('base64'),'.config/ncm-cli/config.json':Buffer.from('{}').toString('base64'),'.config/ncm-cli/credentials.enc.json':encrypted({appId:'SYNTHETIC-APP',privateKey:pair.privateKey}),'.config/ncm-cli/tokens.enc.json':encrypted({namedToken:'SYNTHETIC-SESSION',namedRefreshToken:'SYNTHETIC-REFRESH',namedTokenExpireAt:Date.now()+3600000})};
const credential=Buffer.from(JSON.stringify({schema:1,storage:'official',files})).toString('base64');pair.privateKey='';key.fill(0);
async function run(name){
 const req={schema:1,operation:'playlist_detail',call_id:id,credential,network_allowed:true,arguments:{playlist_id:'1'.repeat(32),...(name==='continuation_end'?{offset:'1'}:{})}};
 const env={PATH:'/usr/bin:/bin',TMPDIR:'/private/tmp',LANG:'C',LC_ALL:'C',ARL_SYNTHETIC_TERMINAL_CASE:name};
 const r=cp.spawnSync(process.execPath,['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseTerminalPageMockLoader.mjs'),path.join(__dirname,'fixtures/NetEaseSharedReadBridgeChild.cjs'),bridge,path.join(runtime,'Bridge')],{input:JSON.stringify(req),env,encoding:'utf8',timeout:15000,maxBuffer:524288});
 assert.equal(r.status,0);assert.equal(r.signal,null);const frames=r.stdout.trim().split('\n').map(JSON.parse),done=frames.filter(x=>x.event==='read_complete');assert.equal(done.length,1);
 const result=done[0].result;req.credential='';r.stdout='';const p=result.payload;
 if(name==='missing_null'){assert.equal(result.state,'provider_rejected');assert.equal(result.failure.reason,'provider_resource_missing');}
 else {assert.equal(result.state,'authorized_read');assert.equal(result.provider_result,undefined);
  assert.equal(p.pagination.state,name==='empty_zero'?'stable_observed':name==='continuation_end'?'continuation_end':'drift');
  assert.equal(p.complete,name==='empty_zero');
  if(name!=='closing_drift'){assert(p.pagination.terminal_observations?.length>0);for(const x of p.pagination.terminal_observations){assert.equal(x.fields.code,200);assert.equal(x.fields.sub_code,'10007');assert.equal(x.fields.method,'GET');}}
 }
 reports.push({case:name,result,offset:name==='continuation_end'?1:0});
}
(async()=>{for(const c of ['empty_zero','continuation_end','count_conflict','empty_count_conflict','missing_null','closing_drift'])await run(c);fs.writeFileSync(output,JSON.stringify({cases:reports}),{mode:0o600});console.log(JSON.stringify({status:'PASS',cases:reports.map(x=>({case:x.case,state:x.result.state,complete:x.result.payload?.complete,pagination:x.result.payload?.pagination?.state})),pinned_CLI_executed:true,children_closed:6,real_network:0,real_credentials:0}));})().catch(e=>{console.log(JSON.stringify({status:'FAIL',safe_reason:e.code??e.name,completed_cases:reports.map(x=>x.case),raw_output_saved:false}));process.exitCode=1;});
