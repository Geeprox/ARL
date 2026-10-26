'use strict';
// Pure production token validation and public error projection. No CLI, network,
// real credentials, persistent account state or business effect is invoked.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const file=process.argv[2]||path.join(__dirname,'../integrations/service_runtime/netease_bridge.cjs');
const source=fs.readFileSync(file,'utf8'),prefix=source.slice(0,source.indexOf('\ntry {\n  const request=readRequest();'));
assert(prefix.length>0&&prefix.length<source.length);
const api=new Function('require','__dirname',prefix+'return {coverTokenValidation,acceptCoverToken,providerExchange,context:v=>{readContext=v;}};')(require,path.dirname(file));
let checks=0;const check=(value)=>{assert(value);checks++;};
const secret='SYNTHETIC-TOKEN-NEVER-EXPORT',key='synthetic-nos-key';
const base=()=>({code:200,subCode:200,data:{token:secret,resource:{docId:'1099511650000000123',bucket:'yyimgs',nosKey:key}}});
const context=()=>({cover:{receipts:[],offset:0,tokenCount:1}});
for(const numeric of [false,true]){const value=base();if(numeric)value.data.resource.docId=1099511650000000;api.context(context());api.acceptCoverToken(value,Buffer.from(JSON.stringify(value)),true);check(api.coverTokenValidation(value).valid);}
const cases=[['data_object',v=>{v.data=null;}],['token_string_length',v=>{v.data.token=7;}],['token_string_length',v=>{v.data.token='';}],['token_string_length',v=>{v.data.token='x'.repeat(16385);}],['resource_object',v=>{v.data.resource=[];}],['doc_id_decimal',v=>{v.data.resource.docId='1e12';}],['bucket_yyimgs',v=>{v.data.resource.bucket='other';}],['nos_key_component',v=>{v.data.resource.nosKey='folder/key';}]];
for(const [rule,change] of cases){const value=base();change(value);const ctx=context();api.context(ctx);let caught;try{api.acceptCoverToken(value,Buffer.from(JSON.stringify(value)),true);}catch(error){caught=error;}
 check(caught?.code==='invalid_cover_token_reply');check(caught.coverTokenValidation.failed_rules.includes(rule));check(!Object.hasOwn(caught.coverTokenValidation.types,'token'));check(typeof caught.coverTokenValidation.types.token_type==='string');check(ctx.cover.resourceID===undefined&&ctx.cover.token===undefined);
 const record={path:'/openapi/whale/nos/upload/token/docid',method:'POST',http_status:200,cover_token_validation:caught.coverTokenValidation};
 const projected=api.providerExchange(record,'00000000-0000-4000-8000-000000000001');check(projected.fields.failure_code==='invalid_cover_token_reply');
 const text=JSON.stringify(projected);check(!text.includes(secret)&&!text.includes(key)&&!text.includes('folder/key'));check(projected.fields.cover_token_validation.cover_update_dispatched===false);
}
for(const value of [null,{}, {data:'unexpected'}, {data:{token:secret,resource:{nosKey:key}}}]){const text=JSON.stringify(api.coverTokenValidation(value));check(!text.includes(secret)&&!text.includes(key));}
const ordinary=api.providerExchange({path:'/normal',method:'GET',http_status:200},null);check(!Object.hasOwn(ordinary.fields,'cover_token_validation'));
// Optional end-to-end pinned-SDK fixture: retain the reviewed transport
// harness, change only its synthetic token bucket and relocate its audit output.
// All sockets remain denied by the original harness; no account state is loaded.
let pinnedSDK;
if(process.argv[3]&&process.argv[4]) {
 const cp=require('node:child_process'),originalPath=path.join(__dirname,'NetEasePlaylistCoverUploadBoundaryTests.cjs');
 const output=path.resolve(process.argv[4]);fs.mkdirSync(output,{recursive:true,mode:0o700});
 let driver=fs.readFileSync(originalPath,'utf8');
 const relocate="audit=path.join(root,'build/audit/playlist-cover-20261020.noindex/repair-v9/upload-fixtures');";
 assert(driver.includes(relocate));driver=driver.replace(relocate,'audit='+JSON.stringify(path.join(output,'fixtures'))+';');
 const marker=" } else if(target.hostname==='wanproxy-web.127.net') {";
 assert(driver.includes(marker));driver=driver.replace(marker,"  if(scenario==='bad_token_shape')text=text.replace('\\\"bucket\\\":\\\"yyimgs\\\"','\\\"bucket\\\":\\\"SYNTHETIC-BAD-BUCKET\\\"');\n"+marker);
 const validation=" const bad=scenario.startsWith('bad_');";
 assert(driver.includes(validation));driver=driver.replace(validation,` if(scenario==='bad_token_shape') {
  assert(done);assert.equal(done.result.state,'not_submitted');
  assert.deepEqual(calls,{manifest:1,token:1,nos:0,cover:0});
  fs.writeFileSync(path.join(audit,'complete-result.json'),JSON.stringify(done.result),{mode:0o600});
  const metadata=done.result.provider_exchange.fields;
  assert.equal(metadata.failure_code,'invalid_cover_token_reply');
  assert.deepEqual(metadata.cover_token_validation.failed_rules,['bucket_yyimgs']);
  assert.equal(metadata.cover_token_validation.boundary,'token_reply_before_nos');
  assert.equal(metadata.cover_token_validation.token_accepted,false);
  assert.equal(metadata.cover_token_validation.cover_update_dispatched,false);
  const serialized=JSON.stringify(done.result);
  assert(!serialized.includes('SYNTHETIC-NOS-SECRET-ONLY'));
  assert(!serialized.includes('SYNTHETIC-BAD-BUCKET'));
  assert(!serialized.includes('synthetic-nos-key'));
  reports.push({scenario,state:done.result.state,calls,failed_rules:metadata.cover_token_validation.failed_rules});continue;
 }
`+validation);
 const copy=path.join(output,'PinnedTokenFailureFixture.cjs');fs.writeFileSync(copy,driver,{mode:0o600});
 const run=cp.spawnSync(process.execPath,[copy,path.resolve(file),path.resolve(process.argv[3])],
  {encoding:'utf8',timeout:30000,maxBuffer:4*1048576,env:{...process.env,COVER_CASES:'bad_token_shape'}});
 fs.writeFileSync(path.join(output,'pinned-token.stdout.log'),run.stdout,{mode:0o600});
 fs.writeFileSync(path.join(output,'pinned-token.stderr.log'),run.stderr,{mode:0o600});
 assert.equal(run.signal,null);assert.equal(run.status,0,run.stderr);
 pinnedSDK=JSON.parse(run.stdout);check(pinnedSDK.status==='PASS');
}
process.stdout.write(JSON.stringify({status:'PASS',checks,real_network:0,real_credentials:0,business_effects:0,...(pinnedSDK?{pinnedSDK}:{})})+'\n');
