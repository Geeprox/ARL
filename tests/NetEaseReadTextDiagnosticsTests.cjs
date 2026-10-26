// Synthetic scalar rejection diagnostics; no child process, provider or stored session.
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const sourcePath=path.resolve(process.argv[2]||'integrations/service_runtime/netease_bridge.cjs');
const src=fs.readFileSync(sourcePath,'utf8'),setup=src.slice(0,src.lastIndexOf('\ntry {\n  const request=readRequest();'));
const api=new Function('require','__dirname',setup+'\nreturn {readText,projectReadValue,set(c,d){readContext=c;diagnostic=d;}};')(require,path.dirname(sourcePath));
let count=0;
function exercise(value,limit,field,index,expectedMask,type){
 const events=[],d={phase:'provider',last:'keep',lastValues:{code:200},record(phase,kind,v){events.push(v);this.phase=phase;this.last=kind;this.lastValues=v;}};
 api.set({operation:'search',isWrite:false},d);
 assert.throws(()=>api.readText(value,limit,field,index),e=>e.code==='invalid_result_text');
 const codes=events.filter(x=>x.code<=-97500&&x.code>=-97502);
 assert.deepEqual(codes,[{code:-97500,sub_code:field*10000+(index+1)*256+expectedMask*8+type},{code:-97501,sub_code:typeof value==='string'?Buffer.byteLength(value):0},{code:-97502,sub_code:limit}]);
 assert.equal(d.phase,'provider');assert.equal(d.last,'keep');assert.deepEqual(d.lastValues,{code:200});
 assert.ok(!JSON.stringify(events).includes('SYNTHETIC-SECRET'));count++;
}
exercise('',400,4,3,2,1);exercise(null,200,3,0,1,2);exercise(undefined,400,4,1,1,3);
exercise('SYNTHETIC-SECRET\n',800,1,2,8,1);exercise('中'.repeat(267),800,1,19,4,1);
exercise(' \n ',200,3,4,10,1);exercise({},400,4,0,1,5);
for(const context of [{operation:'search',isWrite:true},{operation:'tracks',isWrite:false}]){
 const events=[];api.set(context,{record(_p,_k,v){events.push(v);}});assert.throws(()=>api.readText('',400,4,0));assert.ok(!events.some(x=>x.code<=-97500));count++;
}
const events=[];api.set({operation:'search',isWrite:false},{record(_p,_k,v){events.push(v);}});assert.equal(api.readText(' Fine ',800,1,0),'Fine');assert.deepEqual(events,[]);count++;
const rows=[{encryptedId:'1'.repeat(32),name:'Synthetic',ar:[{name:'Artist'}],al:{name:'Album'}}];
api.set({operation:'search',isWrite:false},{record(){}});const projected=api.projectReadValue({code:200,data:{records:rows,recordCount:1}},'search');assert.equal(projected.items[0].metadata.album,'Album');count++;
process.stdout.write(JSON.stringify({status:'PASS',groups:count,provider_calls:0,credential_access:0,guard_outcomes_unchanged:true})+'\n');
