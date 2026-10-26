'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const source=fs.readFileSync(process.argv[2],'utf8');
const setup=source.slice(0,source.lastIndexOf('\ntry {'));
const loadAPI=()=>new Function('require','__dirname',setup+'\nreturn {FiniteDiagnostics,captureOutput,rememberSecret,secretFreeProjection,refreshDiagnosticSecrets,store,setDiagnostic(value){diagnostic=value;},hasReadContext(){return readContext!==null;}};')(require,path.dirname(process.argv[2]));
const api=loadAPI();
const output=[],checks=[];
const check=(name,fn)=>{fn();checks.push(name);};
const secrets=['SYNTHETIC-PRIVATE-KEY-ONLY','SYNTHETIC-TOKEN-ONLY','123456','SYNTHETIC-QR-URL-ONLY'];
for(const secret of secrets)api.rememberSecret(secret);
const d=new api.FiniteDiagnostics('00000000-0000-4000-8000-000000000001',x=>output.push(x),api.secretFreeProjection,()=>100,api.refreshDiagnosticSecrets);
api.setDiagnostic(d);
check('create_rejection_keeps_safe_codes',()=>{d.response('qr_create',403,{code:40101,subCode:'12',message:secrets[0],data:{accessToken:secrets[1],qrCodeUrl:secrets[3]}});assert.equal(output.at(-1).code,40101);assert.equal(output.at(-1).kind,'provider_rejected');assert.equal(output.at(-1).sub_code,12);});
check('poll_confirmation',()=>{d.response('qr_poll',200,{code:200,data:{status:802,msg:secrets[0]}});assert.equal(output.at(-1).kind,'confirming');assert.equal(output.at(-1).provider_status,802);});
check('poll_success_not_account_success',()=>{d.response('qr_poll',200,{code:200,data:{status:803,accessToken:{accessToken:secrets[1]}}});assert.equal(output.at(-1).phase,'qr_poll');assert.equal(output.at(-1).kind,'succeeded');});
check('profile_rejection_is_separate',()=>{d.response('account_read',200,{code:301,subCode:7,message:'PRIVATE ACCOUNT '+secrets[0]});assert.equal(output.at(-1).phase,'account_read');assert.equal(output.at(-1).code,301);});
check('expiry',()=>{d.response('qr_poll',200,{code:200,data:{status:800}});assert.equal(output.at(-1).kind,'expired');});
check('unexpected_poll_shape',()=>{d.response('qr_poll',200,{code:200,data:{status:'802'}});assert.equal(output.at(-1).kind,'invalid_response');});
check('signing_error_maps_only_fixed_kind',()=>{d.error(new Error('RSA SHA256 签名失败: '+secrets[0]),'initialize');assert.equal(output.at(-1).kind,'signing_failed');});
check('network_timeout_category',()=>{d.error({name:'AbortError',message:secrets[0]},'qr_poll');assert.equal(output.at(-1).kind,'network_timeout');});
check('parse_error_category',()=>{d.error({code:'invalid_json',message:secrets[0]},'qr_create');assert.equal(output.at(-1).kind,'invalid_response');});
check('parse_error_keeps_http_status',()=>{d.error({code:'invalid_json',message:secrets[0]},'qr_create',502);assert.equal(output.at(-1).http_status,502);});
check('missing_code_not_success',()=>{d.response('qr_create',200,{message:secrets[0]});assert.equal(output.at(-1).kind,'invalid_response');});
check('secret_codes_redacted',()=>{d.response('qr_create',403,{code:123456,subCode:secrets[0]});assert.equal(output.at(-1).code,null);assert.equal(output.at(-1).sub_code,null);});
for(const value of [true,false,NaN,Infinity,1.5,1e20,{token:secrets[1]},['200'],'200 '+secrets[1],Buffer.from(secrets[1]).toString('base64')]) {
 check('reject_code_type_'+checks.length,()=>{d.response('provider',403,{code:value,subCode:value});assert.equal(output.at(-1).code,null);assert.equal(output.at(-1).sub_code,null);});
}
check('unknown_phase_not_emitted',()=>{const n=output.length;d.record(secrets[0],'succeeded');d.record('bridge',secrets[0]);assert.equal(output.length,n);});
check('deduplicate_poll_states',()=>{d.response('qr_poll',200,{code:200,data:{status:801}});const n=output.length;for(let i=0;i<200;i++)d.response('qr_poll',200,{code:200,data:{status:801}});assert.equal(output.length,n);});
check('strict_message_projection',()=>{for(const secret of secrets)assert.ok(!JSON.stringify(output).includes(secret));for(const row of output)assert.deepEqual(Object.keys(row).sort(),['schema','call_id','event','sequence','phase','kind','http_status','code','sub_code','provider_status','elapsed_ms'].sort());});
check('capture_failed_json_no_raw_output',()=>{const n=output.length;const e=new api.FiniteDiagnostics(d.callID,x=>output.push(x),api.secretFreeProjection,()=>100);api.setDiagnostic(e);api.captureOutput(JSON.stringify({success:false,status:secrets[0],error:secrets[1],message:secrets[3]}));assert.equal(output.length,n+1);assert.equal(output.at(-1).kind,'unconfirmed');});
check('bounded_diagnostics',()=>{for(let i=0;i<500;i++)d.record('provider',i%2?'started':'succeeded');assert.equal(d.count,128);});
for(const [p,expected] of [['/openapi/music/basic/user/oauth2/qrcode/key/get/v2','qr_create'],['/openapi/music/basic/oauth2/device/login/qrcode/get','qr_poll'],['/openapi/music/basic/user/profile/get/v2','account_read'],['/unknown','provider']])check('phase_'+expected,()=>assert.equal(api.FiniteDiagnostics.phaseFor(p),expected));
const fresh=()=>{
 const a=loadAPI(),rows=[];
 const diag=new a.FiniteDiagnostics(d.callID,x=>rows.push(x),a.secretFreeProjection,()=>100,a.refreshDiagnosticSecrets);
 a.setDiagnostic(diag);assert.equal(a.hasReadContext(),false);
 return {a,diag,rows};
};
check('leading_zero_secret_checked_before_normalization',()=>{
 const {a,diag,rows}=fresh();a.rememberSecret('012345');
 diag.response('provider',403,{code:'012345',subCode:'-012345'});
 assert.equal(rows.at(-1).code,null);assert.equal(rows.at(-1).sub_code,null);
 assert.equal(diag.number('012345'),null);assert.ok(!JSON.stringify(rows).includes('12345'));
});
check('normalized_numeric_secret_check_retained',()=>{
 const {a,diag}=fresh();a.rememberSecret('12345');
 assert.equal(diag.number('012345'),null);assert.equal(diag.number(12345),null);
 assert.equal(diag.number('000042'),42);assert.equal(diag.number('-000042'),-42);
});
const deviceID='00000000-0000-4000-8000-000000000002';
function encryptedTokens(value) {
 const key=crypto.createHash('sha256').update(deviceID).digest(),iv=Buffer.alloc(16,7);
 try {const cipher=crypto.createCipheriv('aes-256-cbc',key,iv);
  return JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([cipher.update(JSON.stringify(value)),cipher.final()]).toString('hex')});
 } finally {key.fill(0);}
}
check('ordinary_login_store_refreshes_rotated_token_without_read_context',()=>{
 const {a,diag,rows}=fresh();a.store('.netease_mcp_device.json',JSON.stringify({deviceId:deviceID}));
 a.store('.config/ncm-cli/tokens.enc.json',encryptedTokens({namedToken:'SYNTHETIC-OLD-TOKEN-ONLY'}));
 a.store('.config/ncm-cli/tokens.enc.json',encryptedTokens({namedToken:'654321',namedRefreshToken:'076543'}));
 assert.equal(a.hasReadContext(),false);assert.equal(a.secretFreeProjection('654321'),false);
 assert.equal(a.secretFreeProjection('076543'),false);assert.equal(a.secretFreeProjection('SYNTHETIC-OLD-TOKEN-ONLY'),false);
 diag.response('account_read',403,{code:654321,subCode:'076543'});
 assert.equal(rows.at(-1).code,null);assert.equal(rows.at(-1).sub_code,null);
 for(const secret of ['654321','076543','76543'])assert.ok(!JSON.stringify(rows).includes(secret));
});
check('unsaved_poll_tokens_registered_before_same_response_codes',()=>{
 const {a,diag,rows}=fresh();
 diag.response('qr_poll',403,{code:'054321',subCode:678901,data:{status:803,accessToken:{accessToken:'054321',refreshToken:'678901'}}});
 assert.equal(rows.at(-1).code,null);assert.equal(rows.at(-1).sub_code,null);
 assert.equal(a.secretFreeProjection('054321'),false);assert.equal(a.secretFreeProjection('678901'),false);
 for(const secret of ['054321','54321','678901'])assert.ok(!JSON.stringify(rows).includes(secret));
});
check('unsaved_direct_refresh_tokens_registered_before_projection',()=>{
 const {diag,rows}=fresh();
 diag.response('provider',403,{code:876543,subCode:'065432',data:{accessToken:'876543',refreshToken:'065432'}});
 assert.equal(rows.at(-1).code,null);assert.equal(rows.at(-1).sub_code,null);
});
check('response_secret_refresh_keeps_existing_bounds_and_emits_nothing_on_overflow',()=>{
 const {diag,rows}=fresh();
 assert.throws(()=>diag.response('qr_poll',200,{code:200,data:{accessToken:{accessToken:'X'.repeat(262145)}}}),e=>e.code==='private_pattern_limit');
 assert.equal(rows.length,0);
});
process.stdout.write(JSON.stringify({status:'PASS',checks:checks.length,passed:checks,real_provider_calls:0,real_secrets:0})+'\n');
