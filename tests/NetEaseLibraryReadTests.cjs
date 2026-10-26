'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const candidate=process.argv[2],runtime=process.argv[3],output=process.argv[4],specFile=path.join(__dirname,'fixtures/NetEaseLibraryContracts.json'),specs=JSON.parse(fs.readFileSync(specFile));
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(runtime,'NetEase/dist/index.js'))).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');
const id='00000000-0000-4000-8000-000000000001',key=crypto.createHash('sha256').update(id).digest();
function encrypted(value){const iv=crypto.randomBytes(16),c=crypto.createCipheriv('aes-256-cbc',key,iv);return Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([c.update(JSON.stringify(value)),c.final()]).toString('hex')})).toString('base64');}
const pair=crypto.generateKeyPairSync('rsa',{modulusLength:2048,privateKeyEncoding:{type:'pkcs8',format:'pem'},publicKeyEncoding:{type:'spki',format:'pem'}});
const files={'.netease_mcp_device.json':Buffer.from(JSON.stringify({deviceId:id})).toString('base64'),'.config/ncm-cli/config.json':Buffer.from('{}').toString('base64'),'.config/ncm-cli/credentials.enc.json':encrypted({appId:'SYNTHETIC-LIBRARY-APP',privateKey:pair.privateKey}),'.config/ncm-cli/tokens.enc.json':encrypted({namedToken:'SYNTHETIC-LIBRARY-SESSION',namedRefreshToken:'SYNTHETIC-LIBRARY-REFRESH',namedTokenExpireAt:Date.now()+3600000})};
pair.privateKey='';key.fill(0);
let credential=Buffer.from(JSON.stringify({schema:1,storage:'official',files})).toString('base64');
const cases=Object.keys(specs).map(operation=>({operation,scenario:'success'})).concat([
 {operation:'album_get',scenario:'wrong_method'},{operation:'search_all',scenario:'wrong_path'},
 {operation:'search_album',scenario:'extra_required'},{operation:'song_lyric',scenario:'wrong_auth'},
 {operation:'search_playlist',scenario:'http403'},{operation:'album_tracks',scenario:'oversize'},
 {operation:'artist_songs',scenario:'artist_bad_start'},{operation:'artist_songs',scenario:'artist_secret_message'},
 {operation:'album_collected',scenario:'contradictory_count'},
 {operation:'playlist_collected',scenario:'success',arguments:{},public_arguments:{}},
 {operation:'playlist_collected',scenario:'wrong_path'},
 {operation:'playlist_get_tags',scenario:'wrong_method'},
 {operation:'playlist_get_tags',scenario:'http403'},
 {operation:'playlist_collected',scenario:'contradictory_count'}]);
const reports=[],fixtures=[];
for(const c of cases){
 const args=c.arguments??specs[c.operation].arguments,call='00000000-0000-4000-8000-000000000002';
 const input={schema:1,operation:c.operation,call_id:call,credential,network_allowed:true,arguments:args};
 const p=cp.spawnSync(process.execPath,['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseLibraryLoader.mjs'),path.join(__dirname,'fixtures/NetEaseLibraryBridgeChild.cjs'),candidate,path.join(runtime,'Bridge')],{input:JSON.stringify(input),env:{PATH:'/usr/bin:/bin',TMPDIR:'/tmp',LANG:'C',ARL_LIBRARY_SPECS:specFile,ARL_LIBRARY_OPERATION:c.operation,ARL_LIBRARY_SCENARIO:c.scenario,ARL_LIBRARY_ARGUMENTS:JSON.stringify(args)},encoding:'utf8',timeout:15000,maxBuffer:2097152});
 input.credential='';
 assert.equal(p.status,0,JSON.stringify({case:c,status:p.status,stderr:p.stderr?.slice(-1000)}));
 const frames=p.stdout.trim().split('\n').map(s=>JSON.parse(s,(_k,v,c)=>typeof v==='number'&&Number.isInteger(v)&&!Number.isSafeInteger(v)?JSON.rawJSON(c.source):v)),end=frames.filter(f=>f.event==='read_complete');p.stdout='';
 assert.equal(end.length,1,JSON.stringify({case:c,events:frames.map(f=>({event:f.event,kind:f.kind,code:f.code}))}));
 const result=end[0].result;
 if(c.scenario==='success'){
  assert.equal(result.state,'authorized_read',JSON.stringify({case:c,result}));
  assert.equal(result.payload.complete,false);const r=result.payload.library;
  assert.equal(r.operation,c.operation);assert.equal(r.coverage,'single_provider_response');
  assert.equal(r.provider_record.fields.data.padding,'TAIL');assert.equal(r.provider_record.fields.data.records.length,2);
  assert.equal(r.provider_record.fields.data.accessToken,undefined);assert.ok(r.provider_record.omitted_authentication_fields.includes('accesstoken'));
  assert.ok(JSON.stringify(r).includes('9007199254740993'));assert.ok(!JSON.stringify(r).includes('SYNTHETIC-RESPONSE-SECRET'));
 } else if(c.scenario==='artist_bad_start'||c.scenario==='artist_secret_message'){
  assert.equal(result.state,'provider_rejected');
  assert.equal(result.failure.http_status,200);
  assert.equal(result.provider_result.fields.code,400);
  assert.equal(result.provider_result.fields.provider_message,c.scenario==='artist_bad_start'?'发布开始时间格式错误':undefined);
  assert.ok(!JSON.stringify(result).includes('SYNTHETIC-LIBRARY-SESSION'));
 } else if(c.scenario==='contradictory_count'){
  assert.equal(result.state,'authorized_read');
  assert.equal(result.payload.library.provider_record.fields.data.records.length,1);
  assert.equal(result.payload.library.provider_record.fields.data.recordCount,0);
  assert.equal(result.payload.complete,false);
 } else if(c.scenario==='http403')assert.equal(result.state,'provider_rejected');
 else if(c.scenario==='oversize'){assert.equal(result.state,'contract_rejected');assert.equal(result.failure.reason,'response_too_large');assert.equal(result.failure.output_limit_bytes,262144);}
 else assert.equal(result.state,'contract_rejected');
 fixtures.push({tool:'mio_netease_'+c.operation,arguments:c.public_arguments??specs[c.operation].public_arguments,operation:c.operation,result,correlation_id:call});
 reports.push({...c,state:result.state,reason:result.failure?.reason??null,child_closed:true});
}
credential='';
fs.writeFileSync(output,JSON.stringify({cases:fixtures}));
process.stdout.write(JSON.stringify({status:'PASS',cases:reports,official_pinned_CLI_executed:true,production_network_gates_executed:true,real_credentials:false,real_network:false})+'\n');
