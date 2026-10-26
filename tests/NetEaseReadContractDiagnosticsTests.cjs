'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const candidate=fs.readFileSync(process.argv[2],'utf8');
const baseline=fs.readFileSync(process.argv[3],'utf8');
function factory(source,filename){
 const split=source.lastIndexOf('\ntry {');assert.ok(split>0);
 return new Function('require','__dirname',source.slice(0,split)+`\nreturn {
  fault,strictJSON,validateManifests,projectRead,FiniteDiagnostics,
  context:value=>{readContext=value;},trace:value=>{diagnostic=value;}
 };`)(require,path.dirname(filename));
}
const api=factory(candidate,process.argv[2]),old=factory(baseline,process.argv[3]);
const mapping=JSON.parse(fs.readFileSync(process.argv[4],'utf8')).codes;
let checks=0;const check=(fn)=>{fn();checks++;};
let rows=[];
const trace=new api.FiniteDiagnostics('00000000-0000-4000-8000-000000000001',x=>rows.push(x));
api.trace(trace);
check(()=>{api.context(null);api.fault('invalid_manifest');assert.equal(rows.length,0);});
api.context({operation:'user_playlists'});
for(const [name,number]of Object.entries(mapping))check(()=>{
 const before={phase:trace.phase,last:trace.last,lastValues:trace.lastValues,failed:trace.failed,failure:trace.failure};
 const e=api.fault(name);assert.equal(e.code,name);assert.equal(e.message,name);
 assert.equal(rows.at(-1).phase,'bridge');assert.equal(rows.at(-1).kind,'ignored');assert.equal(rows.at(-1).code,number);
 assert.deepEqual({phase:trace.phase,last:trace.last,lastValues:trace.lastValues,failed:trace.failed,failure:trace.failure},before);
});
check(()=>{const n=rows.length;api.fault('ARL-SYNTHETIC-PRIVATE-NOT-A-KNOWN-CODE');assert.equal(rows.length,n);});
check(()=>{assert.ok(!JSON.stringify(rows).includes('ARL-SYNTHETIC-PRIVATE'));assert.equal(new Set(rows.map(r=>r.sequence)).size,rows.length);});
check(()=>{trace.record('account_read','network_unavailable');const failure=trace.failure;api.fault('invalid_read_method');assert.equal(trace.failure,failure);assert.equal(trace.phase,'account_read');assert.equal(trace.failed,true);});
check(()=>{api.trace(new api.FiniteDiagnostics('00000000-0000-4000-8000-000000000001',()=>{throw Error('synthetic emit failure');}));assert.equal(api.fault('invalid_manifest').code,'invalid_manifest');});
api.trace(null);
const good={manifests:{root:{sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[{
 name:'created',path:'/openapi/music/basic/playlist/created/get/v2',http_method:'GET',auth_required:true,
 parameters:[{name:'limit',in:'query',type:'integer',required:true},{name:'offset',in:'query',type:'integer',required:true}]
}]}}};
const copy=x=>JSON.parse(JSON.stringify(x));
const cases=[['valid',x=>{}],['missing root',x=>{delete x.manifests.root;}],['wrong group',x=>{x.manifests.root.sub_resources[0].name='other';}],
 ['duplicate group',x=>{x.manifests.root.sub_resources.push(x.manifests.root.sub_resources[0]);}],['missing group',x=>{delete x.manifests.playlist;}],
 ['unknown method field',x=>{x.manifests.playlist.methods[0].extra='ARL-SYNTHETIC-PRIVATE';}],['write method',x=>{x.manifests.playlist.methods[0].http_method='POST';}],
 ['unauthenticated',x=>{x.manifests.playlist.methods[0].auth_required=false;}],['other path',x=>{x.manifests.playlist.methods[0].path='/openapi/music/other';}],
 ['parameter object',x=>{x.manifests.playlist.methods[0].parameters={};}],['metadata',x=>{x.manifests.playlist.methods[0].parameters[0].metadata={};}],
 ['default',x=>{x.manifests.playlist.methods[0].parameters[0].default=50;}],['fixed params',x=>{x.manifests.playlist.methods[0].fixed_params={extra:'ARL-SYNTHETIC-PRIVATE'};}],
 ['missing offset',x=>{x.manifests.playlist.methods[0].parameters.pop();}],['duplicate name',x=>{x.manifests.playlist.methods[0].parameters[1].name='limit';}],
 ['wrong location',x=>{x.manifests.playlist.methods[0].parameters[0].in='path';}],['custom type',x=>{x.manifests.playlist.methods[0].parameters[0].type='file_upload';}]];
function outcome(instance,value){instance.context({operation:'user_playlists',arguments:{}});try{return {accepted:true,result:JSON.stringify(instance.validateManifests(value))};}catch(e){return {accepted:false,code:e.code};}}
for(const [name,mutate]of cases)check(()=>{const value=copy(good);mutate(value);assert.deepEqual(outcome(api,value),outcome(old,value),name);});
check(()=>{rows=[];api.trace(new api.FiniteDiagnostics('00000000-0000-4000-8000-000000000001',r=>rows.push(r)));api.context({operation:'user_playlists'});
 assert.throws(()=>api.strictJSON(Buffer.from('{"private":"ARL-SYNTHETIC-PRIVATE","private":1}')),e=>e.code==='duplicate_json_key');assert.equal(rows[0].code,mapping.duplicate_json_key);assert.ok(!JSON.stringify(rows).includes('ARL-SYNTHETIC-PRIVATE'));});
check(()=>{rows=[];const d=new api.FiniteDiagnostics('00000000-0000-4000-8000-000000000001',r=>rows.push(r));api.trace(d);for(let n=0;n<200;n++)api.fault('invalid_manifest');assert.equal(rows.length,128);});
check(()=>{const start='function installNetworkBoundary',end='function validateManifests';assert.equal(candidate.slice(candidate.indexOf(start),candidate.indexOf(end)),baseline.slice(baseline.indexOf(start),baseline.indexOf(end)));});
check(()=>{const start='function validateManifests',end='function inspectSession';assert.equal(candidate.slice(candidate.indexOf(start),candidate.indexOf(end)),baseline.slice(baseline.indexOf(start),baseline.indexOf(end)));});
check(()=>{const start='function projectRead',end='// BEGIN BOUNDED_PAGINATION';assert.equal(candidate.slice(candidate.indexOf(start),candidate.indexOf(end)),baseline.slice(baseline.indexOf(start),baseline.indexOf(end)));});
process.stdout.write(JSON.stringify({status:'PASS',checks,guard_outcome_pairs:cases.length,closed_codes:Object.keys(mapping).length,real_network:0,real_credentials:0,official_CLI_started:false})+'\n');
