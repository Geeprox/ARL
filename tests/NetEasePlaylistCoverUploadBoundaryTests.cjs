'use strict';
// Actual pinned SDK, synthetic credentials and responses; all sockets denied.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),audit=path.join(root,'build/audit/playlist-cover-20261020.noindex/repair-v9/upload-fixtures');
const bridge=process.argv[2]||path.join(root,'integrations/service_runtime/netease_bridge.cjs');
const runtime=process.argv[3]||require('node:path').resolve(__dirname,'../vendor/release/ARL.resources/Contents/Resources/ServiceRuntime');
fs.mkdirSync(audit,{recursive:true,mode:0o700});
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(runtime,'NetEase/dist/index.js'))).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');
const image=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=','base64'),imagePath=path.join(audit,'fixture.png');
fs.writeFileSync(imagePath,image,{mode:0o600});
const fixtureFetch=String.raw`import https from 'node:https';import fs from 'node:fs';
export default async function fetch(url,options) {
 const target=new URL(url),scenario=process.env.COVER_SCENARIO;
 const r=https.request(url,options);r.end();
 let text;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest') {
  const method={name:'updateCover',path:'/openapi/music/basic/playlist/cover/update',http_method:'POST',auth_required:true,
    parameters:[{name:'playlistId',in:'query',type:'string',required:true},{name:'picIds',in:'query',type:'imgs_file_upload',required:true}],
    min_cli_version:'0.1.2'};
  if(scenario==='bad_manifest')method.path='/openapi/music/basic/playlist/delete';
  if(scenario==='bad_type')method.parameters[1].type='file';
  text=JSON.stringify({manifests:{root:{methods:[],sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[method],sub_resources:[]}},notices:[]});
 } else if(target.pathname==='/openapi/whale/nos/upload/token/docid') {
  const nosKey=scenario==='opaque_key'?'synthetic/nos+key=%2F':
    scenario==='bad_nos_key_empty'?'':scenario==='bad_nos_key_control'?'synthetic\nkey':
    scenario==='bad_nos_key_dot'?'..':scenario==='bad_nos_key_surrogate'?'\ud800':
    scenario==='bad_nos_key_long'?'x'.repeat(513):'synthetic-nos-key';
  text='{"code":200,"subCode":200,"data":{"token":"SYNTHETIC-NOS-SECRET-ONLY","outerUrl":"https://nos.netease.com/yyimgs/synthetic?Signature=SYNTHETIC-NOS-SIGNATURE-ONLY&Expires=1792512188&NOSAccessKeyId=SYNTHETIC-NOS-ACCESS-ONLY","resource":{"id":1034,"docId":1099511650000000123,"bucket":"yyimgs","nosKey":'+JSON.stringify(nosKey)+',"fast":'+String(scenario==='fast')+'}}}';
 } else if(target.hostname==='wanproxy-web.127.net') {
  text=JSON.stringify({offset:Number(target.searchParams.get('offset'))+options.body.length,context:'SYNTHETIC-UPLOAD-CONTEXT'});
 } else if(target.pathname==='/openapi/music/basic/playlist/cover/update') {
  const business=JSON.parse(JSON.parse(options.body).bizContent);
  fs.writeSync(1,JSON.stringify({event:'synthetic_business',business})+'\n');
  if(scenario==='network_loss')throw Error('synthetic_connection_lost_after_dispatch');
  text='{"code":200,"subCode":'+(scenario==='rejected'?'10004':'200')+',"data":{"resourceId":1099511650000000123,"details":{"kept":true,"nullValue":null},"message":"synthetic business reply"}}';
 } else throw Error('fixture_endpoint');
 if(scenario==='large_reply'&&target.pathname.endsWith('/cover/update')){const value=JSON.parse(text,(_key,value,context)=>typeof value==='number'&&Number.isInteger(value)&&!Number.isSafeInteger(value)?JSON.rawJSON(context.source):value);value.data.extra='x'.repeat(250000)+'TAIL';text=JSON.stringify(value);}
 const bytes=Buffer.from(text);return {ok:true,status:200,arrayBuffer:async()=>bytes};
}`;
fs.writeFileSync(path.join(audit,'loader.mjs'),"const source="+JSON.stringify(fixtureFetch)+";\nexport async function load(url,context,nextLoad){if(url.endsWith('/NetEase/node_modules/node-fetch/src/index.js'))return {format:'module',shortCircuit:true,source};return nextLoad(url,context);}");
fs.writeFileSync(path.join(audit,'child.cjs'),String.raw`const fs=require('node:fs'),https=require('node:https'),net=require('node:net'),tls=require('node:tls'),{EventEmitter}=require('node:events');
const output=fs.writeSync.bind(fs),deny=()=>{throw Error('real_network_forbidden');};
net.connect=net.createConnection=tls.connect=deny;net.Socket.prototype.connect=deny;
const calls={manifest:0,token:0,nos:0,cover:0};
https.request=(url,options)=>{const u=new URL(url);if(u.protocol!=='https:')deny();
 if(u.hostname==='openncm.music.163.com') {const kind=u.pathname.endsWith('/manifest')?'manifest':u.pathname.endsWith('/upload/token/docid')?'token':u.pathname.endsWith('/cover/update')?'cover':null;if(!kind)deny();calls[kind]++;}
 else if(u.hostname==='wanproxy-web.127.net'){calls.nos++;}else deny();
 const r=new EventEmitter();r.setTimeout=()=>r;r.end=()=>{};r.destroy=()=>{};return r;};
process.on('exit',()=>output(1,JSON.stringify({event:'synthetic_calls',calls})+'\n'));
new Function('require','__dirname',fs.readFileSync(process.argv[2],'utf8'))(require,process.argv[3]);`);
const rid='1099511650000000123',device='00000000-0000-4000-8000-000000000001',key=crypto.createHash('sha256').update(device).digest();
const pair=crypto.generateKeyPairSync('rsa',{modulusLength:2048,privateKeyEncoding:{format:'pem',type:'pkcs8'},publicKeyEncoding:{format:'pem',type:'spki'}});
const encrypted=x=>{const iv=crypto.randomBytes(16),c=crypto.createCipheriv('aes-256-cbc',key,iv);return Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([c.update(JSON.stringify(x)),c.final()]).toString('hex')})).toString('base64');};
const credential=Buffer.from(JSON.stringify({schema:1,storage:'official',files:{
 '.netease_mcp_device.json':Buffer.from(JSON.stringify({deviceId:device})).toString('base64'),
 '.config/ncm-cli/config.json':Buffer.from('{}').toString('base64'),
 '.config/ncm-cli/credentials.enc.json':encrypted({appId:'synthetic-cover-app',privateKey:pair.privateKey}),
 '.config/ncm-cli/tokens.enc.json':encrypted({namedToken:'SYNTHETIC-ACCOUNT-SESSION',namedRefreshToken:'SYNTHETIC-REFRESH',namedTokenExpireAt:Date.now()+3600000})
}})).toString('base64');key.fill(0);pair.privateKey='';
const reports=[];
for(const scenario of (process.env.COVER_CASES||'fast,upload,opaque_key,rejected,network_loss,large_reply,bad_manifest,bad_type,bad_nos_key_empty,bad_nos_key_control,bad_nos_key_dot,bad_nos_key_surrogate,bad_nos_key_long').split(',')){
 const req={schema:1,operation:'playlist_cover',call_id:'00000000-0000-4000-8000-000000000002',credential,network_allowed:true,business_audit:true,
  arguments:{playlist_id:'1'.repeat(32),image_path:imagePath,image_sha256:crypto.createHash('sha256').update(image).digest('hex'),image_bytes:String(image.length)}};
 const result=cp.spawnSync(process.execPath,['--no-warnings','--experimental-loader',path.join(audit,'loader.mjs'),path.join(audit,'child.cjs'),bridge,path.join(runtime,'Bridge')],
  {input:JSON.stringify(req),encoding:'utf8',timeout:20000,maxBuffer:4*1048576,env:{PATH:'/usr/bin:/bin',LANG:'C',LC_ALL:'C',COVER_SCENARIO:scenario}});
 assert.equal(result.signal,null);assert.equal(result.status,0);
 const frames=result.stdout.trim().split('\n').filter(Boolean).map(x=>JSON.parse(x)),done=frames.find(x=>x.event==='cover_complete'),calls=frames.find(x=>x.event==='synthetic_calls')?.calls;
 const parts=frames.filter(x=>x.event==='cover_result_part');
 assert(parts.length>0 && parts.length===parts[0].parts);
 for(const [i,part] of parts.entries()){assert.equal(part.part,i);assert.equal(part.parts,parts.length);assert.equal(part.sha256,done.result_sha256);assert(Buffer.byteLength(JSON.stringify(part))<=262144);}
 const completeBytes=Buffer.concat(parts.map(x=>Buffer.from(x.payload,'base64')));
 assert.equal(crypto.createHash('sha256').update(completeBytes).digest('hex'),done.result_sha256);
 done.result=JSON.parse(completeBytes);
 const businessRecords=frames.filter(x=>x.event==='business_record').map(x=>Buffer.from(x.payload,'base64').toString('utf8')).join('');
 assert(!businessRecords.includes('SYNTHETIC-NOS-SECRET-ONLY'));assert(!businessRecords.includes('SYNTHETIC-UPLOAD-CONTEXT'));
  for(const secret of ['SYNTHETIC-NOS-SIGNATURE-ONLY','SYNTHETIC-NOS-ACCESS-ONLY']){assert(!businessRecords.includes(secret));assert(!completeBytes.includes(Buffer.from(secret)));}
 const bad=scenario.startsWith('bad_'),badManifest=['bad_manifest','bad_type'].includes(scenario),badToken=scenario.startsWith('bad_nos_key_');
 reports.push({scenario,complete_result_bytes:completeBytes.length,private_frames:parts.length,state:done?.result?.state,calls,business:frames.find(x=>x.event==='synthetic_business')?.business});
 fs.writeFileSync(path.join(audit,'latest-report.json'),JSON.stringify({reports},null,2));
 assert(done,'missing cover completion');
 assert.equal(done.result.state,bad?'not_submitted':scenario==='rejected'?'provider_rejected':scenario==='network_loss'?'outcome_unknown':'submitted');
 assert.equal(calls.cover,bad?0:1);assert.equal(calls.token,badManifest?0:1);assert.equal(calls.nos,bad?0:1);
 if(badToken){assert.deepEqual(done.result.provider_exchange.fields.cover_token_validation.failed_rules,['nos_key_component']);assert.equal(done.result.provider_exchange.fields.cover_token_validation.token_accepted,false);assert.equal(done.result.upload_receipts.length,0);assert.equal(done.result.resource_id,null);}
 if(!bad){assert.equal(done.result.resource_id,rid);assert.equal(done.result.provider_response_complete,scenario!=='network_loss');
  if(scenario==='large_reply'){assert.equal(done.result.provider_response.fields.data.extra.length,250004);assert(done.result.provider_response.fields.data.extra.endsWith('TAIL'));assert(completeBytes.length>180000);assert(parts.length>1);assert(businessRecords.includes('TAIL'));}
  if(scenario!=='network_loss'){assert.equal(done.result.provider_response.fields.data.details.kept,true);assert(completeBytes.includes(Buffer.from('"resourceId":'+rid)),'lossless provider integer');}
  assert(done.result.upload_receipts[0].omitted_authentication_fields.includes('token'));}
}
process.stdout.write(JSON.stringify({status:'PASS',unchanged_pinned_sdk:true,real_network:0,real_credentials:0,reports})+'\n');
