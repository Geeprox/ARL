'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const source=fs.readFileSync(process.argv[2],'utf8');
const setup=source.slice(0,source.lastIndexOf('\ntry {'));
const load=()=>new Function('require','__dirname',setup+'\nreturn {FiniteDiagnostics,rememberSecret,secretFreeProjection,refreshDiagnosticSecrets};')(require,path.dirname(process.argv[2]));
const results=[];
const check=(name,fn)=>{fn();results.push(name);};
const fresh=()=>{const api=load(),rows=[];return {api,rows,d:new api.FiniteDiagnostics('00000000-0000-4000-8000-000000000001',v=>rows.push(v),api.secretFreeProjection,()=>100,api.refreshDiagnosticSecrets)};};
check('unknown_safe_code_and_explanation_retained',()=>{
 const {d,rows}=fresh();
 d.response('effect',200,{code:'UNEXPECTED_COLLECTION_TYPE',message:'songIdList: expected JSON array'});
 assert.equal(rows.at(-1).provider_code,'UNEXPECTED_COLLECTION_TYPE');
 assert.equal(rows.at(-1).provider_message,'songIdList: expected JSON array');
 d.response('effect',200,{code:400,message:'歌曲权限校验失败'});
 assert.equal(rows.at(-1).code,400);assert.equal(rows.at(-1).provider_message,'歌曲权限校验失败');
});
check('registered_and_encoded_secrets_removed_before_preserving_reason',()=>{
 const {api,d,rows}=fresh(),secret='Private+/Known=Value_493';
 api.rememberSecret(secret);
 const forms=[secret,Buffer.from(secret).toString('base64'),Buffer.from(secret).toString('base64url'),encodeURIComponent(secret),encodeURIComponent(encodeURIComponent(secret)),secret.split('').map(c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0')).join('')];
 for(const value of forms) {
  d.response('effect',200,{code:400,message:'songIdList: expected JSON array; detail '+value});
  assert(rows.at(-1).provider_message.startsWith('songIdList: expected JSON array'));
  for(const original of forms)assert(!JSON.stringify(rows.at(-1)).includes(original));
 }
});
check('account_identifiers_urls_headers_signatures_controls_removed',()=>{
 const {d,rows}=fresh();
 const message='songIdList: expected JSON array\nAuthorization: Bearer abcDEF01234567890123456789\n'+
  'account=private@example.invalid; uid=193847562; 11111111111111111111111111111111; https://private.invalid/x?sign=xyz; sign=private-signature; '+String.fromCharCode(0)+'safe explanation';
 d.response('effect',200,{code:400,message});
 const cleaned=rows.at(-1).provider_message;
 assert(cleaned.includes('expected JSON array'));assert(cleaned.includes('safe explanation'));
 for(const value of ['private@example.invalid','193847562','11111111111111111111111111111111','https:','Bearer','private-signature'])assert(!cleaned.includes(value));
 assert(!/[\p{Cc}\p{Cf}\p{Cs}]/u.test(cleaned));
});
check('utf8_limit_applies_after_redaction_and_preserves_whole_scalars',()=>{
 const {api,d,rows}=fresh(),secret='SECRET-AT-TRUNCATION-BOUNDARY';
 api.rememberSecret(secret);
 d.response('effect',200,{code:'NEW_UNRECOGNIZED_REASON_'+'X'.repeat(100),message:'参数类型说明：'.repeat(120)});
 let row=rows.at(-1);assert(Buffer.byteLength(row.provider_code)<=64);assert(Buffer.byteLength(row.provider_message)<=512);
 assert(row.provider_message.startsWith('参数类型说明：'));assert(row.provider_message.endsWith('…'));assert(!row.provider_message.includes('\uFFFD'));
 d.response('effect',200,{code:400,message:'safe '.repeat(97)+secret+' trailing safe explanation'});
 row=rows.at(-1);assert(Buffer.byteLength(row.provider_message)<=512);assert(!row.provider_message.includes('SECRET-AT-TRUNCATION'));
});
check('message_and_msg_keep_distinct_source_and_safe_text',()=>{
 const {d,rows}=fresh();
 d.response('effect',200,{code:400,message:'songIdList: expected JSON array',msg:'歌曲权限校验失败'});
 assert.equal(rows.at(-1).provider_message,'songIdList: expected JSON array');
 assert.equal(rows.at(-1).provider_msg,'歌曲权限校验失败');
});
check('successful_and_auth_responses_do_not_expand_logging',()=>{
 const {d,rows}=fresh();
 for(const phase of ['effect','qr_create','qr_poll','provider','account_read']) {
  d.response(phase,200,{code:phase==='effect'?200:400,message:'must not log',msg:'must not log either',data:{accessToken:'SYNTHETIC-AUTH-ONLY'}});
  for(const field of ['provider_code','provider_message','provider_msg'])assert.equal(rows.at(-1)[field],undefined);
 }
 assert(!JSON.stringify(rows).includes('SYNTHETIC-AUTH'));assert(!JSON.stringify(rows).includes('must not log'));
});
check('direct_projection_has_same_sanitizer_and_frame_bound',()=>{
 const {d,rows}=fresh();
 d.record('effect','provider_rejected',{provider_code:'NEW_SAFE_CODE',provider_message:'reason https://private.invalid/token',provider_msg:'other safe reason',data:{private:'not allowed'}});
 assert.equal(rows.at(-1).provider_code,'NEW_SAFE_CODE');assert(!rows.at(-1).provider_message.includes('https:'));
 assert.equal(rows.at(-1).provider_msg,'other safe reason');assert.equal(rows.at(-1).data,undefined);
 for(let i=0;i<200;i++)d.response('effect',200,{code:400,message:i%2?'first safe reason':'second safe reason'});
 assert.equal(rows.length,128);
});
process.stdout.write(JSON.stringify({status:'PASS',groups:results,real_network:0,real_credentials:0})+'\n');
