'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const candidate=process.argv[2],source=fs.readFileSync(candidate,'utf8');
let setup=source.slice(0,source.lastIndexOf('\ntry {'));
setup=setup.replace('const frame = data => {','const frame = data => { captured.push(data); return;');
const api=new Function('require','__dirname','const captured=[];\n'+setup+
"\nreturn {businessBody,businessEvidence,rememberSecret,captured,enable(){businessAudit={callID:'00000000-0000-4000-8000-000000000002',spanID:'00000000-0000-4000-8000-000000000003'};readContext={operation:'playlist_append',stage:'manifest'};}};")(require,path.dirname(candidate));
// Synthetic input only. The raw local path must not scan or rewrite secret-like values.
const reflection='SYNTHETIC-'+crypto.randomBytes(24576).toString('base64');
for(const n of [32768,16384,8192,4096,1024,256,64,36])api.rememberSecret(reflection.slice(0,n));
const body=Buffer.from(JSON.stringify({code:200,accessToken:reflection,manifests:{playlist:{methods:Array.from({length:60},(_,i)=>({
 name:'synthetic'+i,path:'/openapi/synthetic/read/'+i,http_method:'GET',description:'full business description '+i,
 parameters:[{name:'id',type:'string',in:'query',required:true}],metadata:{label:'Synthetic metadata'}}))}}},null,2)+'\n');
const record={path:'/openapi/v1/ncm/cli/manifest',method:'POST',parameters:{cliVersion:'0.1.7',cachedVersion:'{}'},
 business_text:'{"cliVersion":"0.1.7","cachedVersion":"{}"}',http_status:200,received_bytes:body.length,...api.businessBody(body)};
api.enable();
const start=performance.now();let maximum=0;
for(let iteration=0;iteration<20;iteration++) {
 api.captured.length=0;const began=performance.now();const id=api.businessEvidence('http_response',record);maximum=Math.max(maximum,performance.now()-began);
 const chunks=api.captured.filter(x=>x.record_id===id),bytes=Buffer.concat(chunks.map(x=>Buffer.from(x.payload,'base64')));
 assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),chunks[0].sha256);
 assert.equal(JSON.parse(bytes).body_text,body.toString());
}
const elapsed=performance.now()-start;
assert(maximum<1000&&elapsed<5000,'raw local logging exceeded the IO starvation guard');
console.log(JSON.stringify({status:'PASS',iterations:20,elapsed_ms:Math.round(elapsed),maximum_record_ms:Math.round(maximum),body_bytes:body.length,
 body_sha256:crypto.createHash('sha256').update(body).digest('hex'),raw_business_unchanged:true,synthetic_reflections_unmodified:true,real_credentials:0,real_network:0}));
