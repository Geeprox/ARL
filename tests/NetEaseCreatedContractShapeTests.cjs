'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const candidate=fs.readFileSync(process.argv[2],'utf8'),baseline=fs.readFileSync(process.argv[3],'utf8');
const start='// BEGIN CREATED_CONTRACT_SHAPE',end='// END CREATED_CONTRACT_SHAPE\n';
const stripped=candidate.slice(0,candidate.indexOf(start))+candidate.slice(candidate.indexOf(end)+end.length);
assert.equal(stripped.replace('  recordCreatedContractShape(method);\n',''),baseline);
function factory(source,file){
 const split=source.lastIndexOf('\ntry {');assert.ok(split>0);
 return new Function('require','__dirname',source.slice(0,split)+`\nreturn {
  projectCreatedManifestReply, shape:typeof createdContractShape==='function'?createdContractShape:null,
  record:typeof recordCreatedContractShape==='function'?recordCreatedContractShape:null,
  context:value=>{readContext=value;}, diagnostic:value=>{diagnostic=value;}, FiniteDiagnostics
 };`)(require,path.dirname(file));
}
const api=factory(candidate,process.argv[2]),old=factory(baseline,process.argv[3]);
const base={manifests:{root:{sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[{
 name:'created',path:'/openapi/music/basic/playlist/created/get/v2',http_method:'GET',auth_required:true,
 parameters:[{name:'limit',in:'query',type:'integer',required:true},{name:'offset',in:'query',type:'integer',required:true}]
}]}}};
const copy=x=>JSON.parse(JSON.stringify(x)),method=x=>x.manifests.playlist.methods[0];
let checks=1,differential=0;
const check=fn=>{fn();checks++;},values=m=>api.shape(m).map(row=>row[1]);
const valid=[3,0,1,0,2,2,2,0,1,1,0,0,0,0,0,0,0,0,0,0,0];
check(()=>assert.deepEqual(values(method(base)),valid));
check(()=>{
 const m=copy(method(base));m.fixed_params=null;m.http_method='POST';m.auth_provider=false;
 Object.assign(m.parameters[0],{in:false,location:'query',metadata:{dependent_call:true},transform:{active:true},default:{},required:null});
 const expected=[3,68,2,2,2,2,2,30,1,1,0,0,0,1,1,1,1,1,0,0,0];
 assert.deepEqual(values(m),expected);
 m.auth_provider='SYNTHETIC_UNKNOWN';m.parameters[0].in='SYNTHETIC_UNKNOWN';
 const next=[...expected];next[1]=324;next[3]=6;next[7]=1310;next[18]=1;assert.deepEqual(values(m),next);
});
check(()=>{
 const m=copy(method(base));m.parameters=Array.from({length:6},(_,i)=>({name:i===5?'SYNTHETIC_UNKNOWN':i%2?'offset':'limit',in:'query',type:'integer'}));
 m.parameters[5].metadata={dependent_call:true};
 const v=values(m);assert.equal(v[1],16);assert.deepEqual(v.slice(5,14),[6,6,98,3,2,1,3,0,1]);assert.equal(v[20],0);
 m.parameters=Array(4096).fill({name:'limit',in:'query',type:'integer'});m.parameters[4095]={name:'offset',in:'query',type:'integer',default:[]};
 const a=values(m);assert.equal(a[5],4096);assert.equal(a[6],4096);assert.equal(a[15],1);assert.equal(a[11],4094);assert.equal(a[20],0);
 m.parameters.push(null);const b=values(m);assert.equal(b[5],4097);assert.equal(b[6],0);assert.equal(b[12],4);assert.equal(b[20],1);
 m.parameters={limit:{metadata:{action:'SYNTHETIC'}}};const c=values(m);assert.equal(c[4],3);assert.equal(c[6],1);assert.equal(c[20],0);assert.equal(c[13],1);
});
function outcome(target,value){
 target.context({operation:'user_playlists',isWrite:false});
 try{return {ok:target.projectCreatedManifestReply(value)};}catch(error){return {code:error.code};}
}
check(()=>{
 const input=copy(base),m=method(input);
 m.parameters={limit:{type:'integer',in:'query'},offset:{type:'integer',in:'query'}};
 assert.deepEqual(values(m),[3,24,1,0,3,2,2,0,1,1,0,0,0,0,0,0,0,0,0,0,0]);
 const before=outcome(old,copy(input));
 Object.assign(m.parameters.limit,{metadata:{dependent_call:true},transform:{active:true},default:{},required:null});
 assert.deepEqual(values(m),[3,24,1,0,3,2,2,30,1,1,0,0,0,1,1,1,1,1,0,0,0]);
 assert.deepEqual(outcome(old,copy(input)),before);assert.deepEqual(outcome(api,copy(input)),before);
});
check(()=>{
 const m=copy(method(base));
 m.parameters={SYNTHETIC_UNKNOWN_KEY:{name:'limit',in:'query',type:'integer'},offset:{name:'limit',in:'query',type:'integer'}};
 const v=values(m);assert.deepEqual(v.slice(5,13),[2,2,64,2,0,0,1,2]);assert.equal(v[20],0);
 m.parameters={limit:{name:null,type:'integer',in:'query'},offset:{name:'SYNTHETIC_UNKNOWN_NAME',type:'integer',in:'query'}};
 const w=values(m);assert.equal(w[7],32);assert.equal(w[10],2);assert.equal(w[12],3);
 assert.ok(!JSON.stringify(api.shape(m)).includes('SYNTHETIC'));
});
for(const field of [null,false,true,0,1,'SYNTHETIC_SECRET',[],[null],{},
 {type:'integer',in:'query',metadata:[],transform:{},default:null},
 {type:'integer',in:'query',metadata:{dependent_call:true},transform:{active:true},default:[]}])check(()=>{
 const m=copy(method(base));m.parameters={limit:field,offset:{type:'integer',in:'query'}};
 const v=values(m);assert.equal(v[4],3);assert.equal(v[5],2);assert.equal(v[6],2);assert.equal(v[20],0);
 assert.equal(v[1],24);assert.equal(v[7]&1,0);assert.ok(!JSON.stringify(api.shape(m)).includes('SYNTHETIC'));
 // Equivalence to exactly the pinned CLI's key-then-own-name spread semantics.
 const array={...m,parameters:Object.entries(m.parameters).map(([name,value])=>({name,...value}))};
 const av=values(array);for(const i of [5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20])assert.equal(v[i],av[i]);
});
check(()=>{
 const m=copy(method(base));m.parameters=Object.fromEntries(Array.from({length:4096},(_,i)=>['SYNTHETIC_'+i,{name:i===4095?'offset':'limit',type:'integer',in:'query',...(i===4095?{metadata:{active:true},default:{},transform:{active:true}}:{})}]));
 const v=values(m);assert.equal(v[5],4096);assert.equal(v[6],4096);assert.equal(v[11],4094);assert.equal(v[13],1);assert.equal(v[14],1);assert.equal(v[15],1);assert.equal(v[20],0);
 m.parameters.SYNTHETIC_EXTRA=null;const w=values(m);assert.equal(w[5],4097);assert.equal(w[6],0);assert.equal(w[12],4);assert.equal(w[20],1);
});
for(const parameter of [undefined,null,false,true,0,1,'SYNTHETIC_SECRET',[],{}])check(()=>{
 const m=copy(method(base));if(parameter===undefined)delete m.parameters;else m.parameters=parameter;
 const v=values(m);const inspectable=Array.isArray(parameter)||parameter!==null&&typeof parameter==='object';
 assert.equal(v[20],inspectable?0:2);assert.equal(v[6],0);assert.equal(v[12],inspectable?3:4);
 assert.ok(!JSON.stringify(api.shape(m)).includes('SYNTHETIC'));
});
const variants={http_method:['GET','POST','PATCH',null,1],auth_required:[true,false,null,1],auth_provider:['netease','',null,false,0,'unknown',{},[]],
 fixed_params:[{},null,[],{unknown:'SYNTHETIC'},false],parameters:[method(base).parameters,null,{},[],[null],Array(129).fill({name:'limit'})],
 path:[method(base).path,'/openapi/music/basic/playlist/create','/openapi//music',null,2],metadata:[null,{},[],{action:'SYNTHETIC'},false],preprocess:[null,{},[],{action:'SYNTHETIC'},false]};
function compare(input){
 check(()=>{
  const serialized=JSON.stringify(input),before=outcome(old,input);assert.deepEqual(outcome(api,input),before);assert.equal(JSON.stringify(input),serialized);
  const v=values(method(input));assert.equal(v[20]===0&&v[1]===0&&v[7]===0&&v[12]===0,Object.hasOwn(before,'ok'));
 });differential++;
}
for(const [key,entries]of Object.entries(variants))for(const value of [undefined,...entries]){
 const input=copy(base);if(value===undefined)delete method(input)[key];else method(input)[key]=copy(value);compare(input);
}
const fieldVariants={name:['limit','offset','unknown',null],type:['string','number','integer','boolean',null,'object'],
 in:['query','body',null,false,0,'',{},[]],location:['query','body',null,false,0,'',{},[]],
 required:[true,false,null,0,'true'],metadata:[null,{},[],false,{dependent_call:true}],transform:[null,{},[],false,{active:true}],
 default:[null,0,false,'',{},[],{dependency:true}]};
for(const [key,entries]of Object.entries(fieldVariants))for(const value of [undefined,...entries]){
 const input=copy(base);if(value===undefined)delete method(input).parameters[0][key];else method(input).parameters[0][key]=copy(value);compare(input);
}
for(const auth of [false,0,'','unknown'])for(const location of [false,0,'','other','query']){
 const input=copy(base);method(input).auth_provider=auth;Object.assign(method(input).parameters[0],{in:location,location:'query'});
 compare(input);const v=values(method(input));check(()=>assert.equal((v[1]&(1<<8))===0,auth!=='unknown'));check(()=>assert.equal(v[18]===0,location!=='other'));
}
check(()=>{
 const m=copy(method(base));m.path='SYNTHETIC_SECRET_ROUTE';m.auth_provider='SYNTHETIC_SECRET_PROVIDER';
 m.parameters[0]={name:'SYNTHETIC_SECRET_NAME',metadata:{secret:'SYNTHETIC_SECRET_VALUE'},transform:[],default:{secret:'SYNTHETIC_SECRET_VALUE'}};
 assert.ok(!JSON.stringify(api.shape(m)).includes('SYNTHETIC'));assert.ok(api.shape(m).every(row=>row.every(Number.isSafeInteger)));
});
for(const count of [0,106,107,108,126,127,128])check(()=>{
 const rows=[],diag=new api.FiniteDiagnostics('synthetic-call',row=>rows.push(row),()=>true,()=>10);diag.count=count;
 diag.phase='account_read';diag.last='prior';diag.lastValues={kind:'succeeded'};
 const prior={phase:diag.phase,last:diag.last,lastValues:diag.lastValues,failure:diag.failure,failed:diag.failed};
 api.context({operation:'user_playlists',isWrite:false});api.diagnostic(diag);api.record(method(base));api.record(method(base));
 assert.equal(rows.length,count<=106?21:count<128?1:0);
 if(count<=106)assert.deepEqual(rows.map(row=>[row.code,row.sub_code]),api.shape(method(base)));
 else if(rows.length)assert.deepEqual(rows.map(row=>[row.code,row.sub_code]),[[-97120,3]]);
 rows.forEach((row,i)=>assert.equal(row.sequence,count+i+1));assert.ok(diag.count<=128);
 for(const [key,value]of Object.entries(prior))assert.equal(diag[key],value);api.diagnostic(null);
});
check(()=>{
 const rows=[],diag=new api.FiniteDiagnostics('synthetic-call',row=>rows.push(row),v=>v!=='3',()=>10);
 api.context({operation:'user_playlists',isWrite:false});api.diagnostic(diag);api.record(method(base));
 assert.equal(rows[0].sub_code,null);assert.equal(rows.length,21);api.diagnostic(null);
});
check(()=>{
 const diag=new api.FiniteDiagnostics('synthetic-call',()=>{throw Error('synthetic-pipe-failure');},()=>true,()=>10);
 diag.phase='account_read';diag.last='prior';diag.lastValues={kind:'waiting'};
 api.context({operation:'user_playlists',isWrite:false});api.diagnostic(diag);assert.doesNotThrow(()=>api.record(method(base)));
 assert.equal(diag.phase,'account_read');assert.equal(diag.last,'prior');assert.equal(diag.lastValues.kind,'waiting');api.diagnostic(null);
});
check(()=>{
 let calls=0;api.diagnostic({record(){calls++;}});
 for(const operation of ['search','playlist_detail','playlist_create','playlist_append']){api.context({operation,isWrite:false});api.record(method(base));}
 api.context({operation:'user_playlists',isWrite:true});api.record(method(base));assert.equal(calls,0);api.diagnostic(null);
});
process.stdout.write(JSON.stringify({status:'PASS',checks,differential_contract_cases:differential,production_delta_only_observation:true,
 raw_provider_strings_emitted:0,real_network:0,real_credentials:0,installed_writes:0})+'\n');
