'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const source=fs.readFileSync(process.argv[2],'utf8');
let setup=source.slice(0,source.lastIndexOf('\ntry {'));
setup=setup.replace('const frame = data => {','const frame = data => { captured.push(data); return;');
const api=new Function('require','__dirname','const captured=[];\n'+setup+
"return {businessBody,providerExchange,businessEvidence,rememberSecret,FiniteDiagnostics,captured,refreshPath:REFRESH_PATH,enable(){businessAudit={callID:'00000000-0000-4000-8000-000000000002',spanID:'00000000-0000-4000-8000-000000000003'};readContext={operation:'playlist_append',stage:'playlist_append'};}};"
)(require,path.dirname(process.argv[2]));
const precise=Buffer.from(' { "value":987654321098765432109, "data":[1,2.1234567890123456789] }\n');
assert.equal(api.businessBody(precise).body_text,precise.toString());
const binary=Buffer.from([0xff,0,0xc3,0x28]);
const binaryBody=api.businessBody(binary);
assert.equal(binaryBody.body_encoding,'base64');assert(Buffer.from(binaryBody.body_base64,'base64').equals(binary));
const secret='SYNTHETIC-PRIVATE-Token-584923+/=';
api.rememberSecret(secret);
const original={code:200,subCode:10007,playlistId:'1'.repeat(32),songIdList:['2'.repeat(32)],message:'normal business message '.repeat(12000)+'TAIL',
 data:[{songId:'2'.repeat(32),code:'PER_ITEM_FAILURE',msg:'exact per-song explanation'}],
 accessToken:secret,nested:{Authorization:'Bearer '+secret,ordinary:'reflected '+Buffer.from(secret).toString('base64')}};
const bodyBytes=Buffer.from(JSON.stringify(original,null,2)+'\n');
api.enable();
const record={path:'/openapi/music/basic/playlist/song/batch/like',method:'POST',parameters:{playlistId:'1'.repeat(32),songIdList:['2'.repeat(32)]},
 business_text:' {"playlistId":"'+'1'.repeat(32)+'","songIdList":["'+'2'.repeat(32)+'"]} ',
 ...api.businessBody(bodyBytes),received_bytes:bodyBytes.length,http_status:200,elapsed_ms:12};
const recordID=api.businessEvidence('http_response',record);
const chunks=api.captured.filter(x=>x.record_id===recordID);
assert(chunks.length>1);assert.equal(chunks.length,chunks[0].parts);
const bytes=Buffer.concat(chunks.map((x,i)=>{assert.equal(x.part,i);assert(Buffer.from(x.payload,'base64').length<=65536);return Buffer.from(x.payload,'base64');}));
assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),chunks[0].sha256);
const restored=JSON.parse(bytes);
assert.equal(restored.body_text,bodyBytes.toString());assert.equal(restored.business_text,record.business_text);
assert.equal(restored.path,record.path);assert.equal(restored.method,'POST');assert.deepEqual(restored.parameters,record.parameters);
assert(restored.body_text.includes(secret));assert(restored.body_text.includes(Buffer.from(secret).toString('base64')));
assert.deepEqual(JSON.parse(restored.body_text).data,original.data);
const ref=api.providerExchange(record,recordID,original);
assert.deepEqual(Object.keys(ref.fields).sort(),['body_reference','code','elapsed_ms','http_status','method','path','received_bytes','sub_code'].sort());
assert.equal(ref.fields.code,200);assert.equal(ref.fields.sub_code,10007);
assert.equal(ref.fields.body_reference.record_id,recordID);assert.equal(ref.fields.body_reference.complete,true);
assert.equal(ref.fields.body_reference.bytes,bodyBytes.length);
assert(!JSON.stringify(ref).includes(secret));assert(!JSON.stringify(ref).includes('exact per-song explanation'));
const beforeRefresh=api.captured.length;
assert.equal(api.businessEvidence('http_request',{path:api.refreshPath,parameters:{refreshToken:secret}}),null);
assert.equal(api.businessEvidence('http_response',{path:api.refreshPath,body_text:secret}),null);
assert.equal(api.captured.length,beforeRefresh);
const events=[],d=new api.FiniteDiagnostics('00000000-0000-4000-8000-000000000004',x=>events.push(x));
d.response('provider',200,{code:200,subCode:10007,data:null});
assert.equal(events.at(-1).kind,'unconfirmed');assert.equal(events.at(-1).sub_code,10007);
if(process.argv[3])fs.writeFileSync(process.argv[3],api.captured.map(x=>JSON.stringify(x)).join('\n')+'\n',{mode:0o600});
process.stdout.write(JSON.stringify({status:'PASS',full_body_bytes:bytes.length,chunks:chunks.length,exact_business_bytes_preserved:true,
 per_item_result_preserved:true,synthetic_reflections_unmodified:true,authentication_exchange_excluded:true,public_result_metadata_only:true,real_network:0,real_credentials:0})+'\n');
