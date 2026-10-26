'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const candidate=process.argv[2],runtime=process.argv[3],reports=[];
const minenv={PATH:'/usr/bin:/bin',TMPDIR:'/tmp',LANG:'C',LC_ALL:'C'};
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
const cases=[['create_unknown_param','playlist_create'],['append_display','playlist_append'],
 ['append_fixed_override','playlist_append',true],['append_wrong_auth','playlist_append',true]];
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
 for(const [name,operation,rejected] of cases) {
  const request={schema:1,operation,call_id:'00000000-0000-4000-8000-000000000002',credential,network_allowed:true,
   arguments:operation==='playlist_create'?{name:'Synthetic playlist'}:{playlist_id:'1'.repeat(32),song_id:'2'.repeat(32)}};
  const result=await run(['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseWriteFlowMockLoader.mjs'),
   path.join(__dirname,'fixtures/NetEaseWriteRepairBridgeChild.cjs'),candidate,path.join(runtime,'Bridge')],JSON.stringify(request),{...minenv,ARL_SYNTHETIC_WRITE_CASE:name});
  request.credential='';assert.equal(result.code,0);assert.equal(result.signal,null);assert.equal(result.expired,false);assert.equal(result.exceeded,false);
  const frames=result.stdout.trim().split('\n').filter(Boolean).map(row=>JSON.parse(row));result.stdout='';
  const complete=frames.filter(row=>row.event==='write_complete'),observed=frames.filter(row=>row.event==='synthetic_effect_observation');
  reports.push({case:name,state:complete[0]?.result?.state,effect_calls:observed[0]?.calls,rules:frames.filter(x=>x.code<=-97001&&x.code>=-97050).map(x=>x.code),child_closed:result.closed});
  assert.equal(complete.length,1);assert.equal(observed.length,1);
  assert.equal(complete[0].result.state,rejected?'not_submitted':'submitted');assert.equal(observed[0].calls,rejected?0:1);
  if(!rejected)assert.equal(complete[0].result.playlist_id,'1'.repeat(32));
 }
 credential='';process.stdout.write(JSON.stringify({status:'PASS',cases:reports,official_pinned_CLI_executed:true,production_POST_and_business_and_HTTPS_gates_executed:true,real_network:0,real_credentials:0,direct_children_closed:cases.length})+'\n');
}
main().catch(()=>{process.stdout.write(JSON.stringify({status:'FAIL',reason:'synthetic_contract_assertion',cases:reports,raw_output_saved:false})+'\n');process.exitCode=1;});
