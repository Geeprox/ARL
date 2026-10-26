'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const candidate=fs.readFileSync(process.argv[2],'utf8'),baseline=fs.readFileSync(process.argv[3],'utf8');
function factory(source,file){
 const split=source.lastIndexOf('\ntry {');assert.ok(split>0);
 return new Function('require','__dirname',source.slice(0,split)+`\nreturn {
  projectCreatedManifestReply:typeof projectCreatedManifestReply==='function'?projectCreatedManifestReply:null,
  validateManifests,installReadCommandBoundary,captureOutput,
  context:value=>{readContext=value;},
  syntheticSession:()=>{
   const id='00000000-0000-4000-8000-000000000001',key=crypto.createHash('sha256').update(id).digest(),iv=Buffer.alloc(16,7);
   const plain=Buffer.from(JSON.stringify({namedToken:'SYNTHETIC-NOT-A-REAL-SESSION',namedTokenExpireAt:Date.now()+60000}));
   const cipher=crypto.createCipheriv('aes-256-cbc',key,iv),data=Buffer.concat([cipher.update(plain),cipher.final()]);
   files.set('.netease_mcp_device.json',Buffer.from(JSON.stringify({deviceId:id})));
   files.set('.config/ncm-cli/tokens.enc.json',Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:data.toString('hex')})));
   key.fill(0);plain.fill(0);data.fill(0);
  }
 };`)(require,path.dirname(file));
}
const api=factory(candidate,process.argv[2]),old=factory(baseline,process.argv[3]);
const clean={manifests:{root:{sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[{
 name:'created',path:'/openapi/music/basic/playlist/created/get/v2',http_method:'GET',auth_required:true,
 parameters:[{name:'limit',in:'query',type:'integer',required:true},{name:'offset',in:'query',type:'integer',required:true}]
}]}}};
const copy=x=>JSON.parse(JSON.stringify(x));
function project(value){api.context({operation:'user_playlists',isWrite:false,arguments:{}});return api.projectCreatedManifestReply(value);}
let checks=0;const check=fn=>{fn();checks++;};
check(()=>{const p=project(clean);assert.equal(p.manifests.playlist.methods[0].path,clean.manifests.playlist.methods[0].path);});
const extended=copy(clean);
extended.notices=['SYNTHETIC-PRIVATE-NOTICE'];
extended.manifests.root.sub_resources.push({name:'other',path:'other'});
extended.manifests.other={methods:[{name:'write',http_method:'POST'}]};
const method=extended.manifests.playlist.methods[0];
method.extra='SYNTHETIC-PRIVATE-DISPLAY';method.description='SYNTHETIC-PRIVATE-DESCRIPTION';method.aliases=['unreviewed'];
method.metadata=null;method.preprocess=[];method.parameters[0].default=999;method.parameters[1].default='poison';
method.parameters[0].metadata={};method.parameters[0].description='SYNTHETIC-PRIVATE-PARAMETER';method.parameters[0].hidden=true;
check(()=>{old.context({operation:'user_playlists'});assert.throws(()=>old.validateManifests(extended),e=>e.code==='unreviewed_method_field');});
check(()=>{const p=project(extended);assert.ok(!JSON.stringify(p).includes('SYNTHETIC-PRIVATE'));assert.ok(!JSON.stringify(p).includes('poison'));assert.deepEqual(Object.keys(p.manifests).sort(),['playlist','root']);assert.equal(p.manifests.playlist.methods.length,1);assert.deepEqual(p.notices,[]);});
check(()=>{api.context({operation:'user_playlists'});assert.throws(()=>api.validateManifests(extended),e=>e.code==='unreviewed_method_field');});
check(()=>{const original=JSON.stringify(extended);project(extended);assert.equal(JSON.stringify(extended),original);});
const negatives=[
 ['POST',x=>{x.manifests.playlist.methods[0].http_method='POST';}],
 ['auth',x=>{x.manifests.playlist.methods[0].auth_required=false;}],
 ['provider',x=>{x.manifests.playlist.methods[0].auth_provider='other';}],
 ['route',x=>{x.manifests.playlist.methods[0].path='/openapi/music/basic/playlist/create';}],
 ['duplicate group',x=>{x.manifests.root.sub_resources.push({name:'playlist',path:'playlist'});}],
 ['duplicate method',x=>{x.manifests.playlist.methods.push(copy(x.manifests.playlist.methods[0]));}],
 ['missing group',x=>{delete x.manifests.playlist;}],
 ['root alias',x=>{x.manifests.root.sub_resources[0].path='root';}],
 ['prototype alias',x=>{x.manifests.root.sub_resources[0].path='__proto__';}],
 ['missing offset',x=>{x.manifests.playlist.methods[0].parameters.pop();}],
 ['extra business',x=>{x.manifests.playlist.methods[0].parameters.push({name:'playlistId',in:'query',type:'string'});}],
 ['duplicate parameter',x=>{x.manifests.playlist.methods[0].parameters[1].name='limit';}],
 ['custom type',x=>{x.manifests.playlist.methods[0].parameters[0].type='file_upload';}],
 ['body',x=>{x.manifests.playlist.methods[0].parameters[0].in='body';}],
 ['location disagreement',x=>{x.manifests.playlist.methods[0].parameters[0].location='path';}],
 ['fixed business',x=>{x.manifests.playlist.methods[0].fixed_params={other:'value'};}],
 ['method behavior',x=>{x.manifests.playlist.methods[0].preprocess=[{call:'other'}];}],
 ['method metadata',x=>{x.manifests.playlist.methods[0].metadata={call:'other'};}],
 ['dependent call',x=>{x.manifests.playlist.methods[0].parameters[0].metadata={dependent_call:{path:'other'}};}],
 ['auto generate',x=>{x.manifests.playlist.methods[0].parameters[0].metadata={auto_generate:'uuid'};}],
 ['transform',x=>{x.manifests.playlist.methods[0].parameters[0].transform='other';}],
 ['object default',x=>{x.manifests.playlist.methods[0].parameters[0].default={call:'other'};}],
 ['required type',x=>{x.manifests.playlist.methods[0].parameters[0].required='yes';}],
 ['too many groups',x=>{for(let n=0;n<129;n++)x.manifests['extra'+n]={};}],
 ['too many methods',x=>{for(let n=0;n<129;n++)x.manifests.playlist.methods.push({name:'other'+n});}]
];
for(const [name,mutate]of negatives)check(()=>{const value=copy(clean);mutate(value);assert.throws(()=>project(value),undefined,name);});
for(const operation of ['search','playlist_detail','playlist_create','playlist_append'])check(()=>{
 api.context({operation,isWrite:operation.startsWith('playlist_')});assert.throws(()=>api.projectCreatedManifestReply(clean));
});
function section(s,start,end){return s.slice(s.indexOf(start),s.indexOf(end,s.indexOf(start)));}
check(()=>assert.equal(section(candidate,'function validateManifests','function inspectSession'),section(baseline,'function validateManifests','function inspectSession')));
check(()=>assert.equal(section(candidate,'function projectRead','// BEGIN BOUNDED_PAGINATION'),section(baseline,'function projectRead','// BEGIN BOUNDED_PAGINATION')));
check(()=>assert.equal(section(candidate,'function installReadCommandBoundary','function captureOutput'),section(baseline,'function installReadCommandBoundary','function captureOutput')));
check(()=>assert.equal(section(candidate,'function installNetworkBoundary','  // The pinned APIClient'),section(baseline,'function installNetworkBoundary','  // The pinned APIClient')));
check(()=>assert.equal(section(candidate,'      let signed;','    const controller='),section(baseline,'      let signed;','    const controller=')));
(async()=>{
 const commander=require(process.argv[4]);
 const projected=project(extended),ctx={operation:'user_playlists',isWrite:false,arguments:{},failure:null,
   results:{},consumeCount:0,pageDeadline:performance.now()+5000};
 api.context(ctx);ctx.manifests=api.validateManifests(projected);api.syntheticSession();
 const root=new commander.Command('ncm-cli'),group=root.command('playlist'),action=group.command('created');
 for(const parameter of projected.manifests.playlist.methods[0].parameters)action.option('--'+parameter.name+' <value>');
 action.option('--output <value>').option('--userInput <value>');
 let calls=0;
 action.action(options=>{
  assert.equal(options.limit,'50');assert.equal(options.offset,'0');assert.equal(options.output,'json');
  assert.deepEqual(ctx.expectedBusiness,{limit:'50',offset:'0'});
  assert.equal(ctx.activePath,'/openapi/music/basic/playlist/created/get/v2');assert.equal(ctx.activeMethod,'GET');
  calls++;api.captureOutput(JSON.stringify({code:200,data:{recordCount:1,records:[{id:'1'.repeat(32),name:'Synthetic playlist',trackCount:0}]}}));
 });
 api.installReadCommandBoundary(commander);
 await root.parseAsync(['node','synthetic-cli']);
 check(()=>{assert.equal(calls,2);assert.equal(ctx.failure,null);assert.equal(ctx.results.user_playlists.complete,true);assert.equal(ctx.results.user_playlists.pagination.state,'stable_observed');assert.equal(ctx.results.user_playlists.items.length,1);});
 process.stdout.write(JSON.stringify({status:'PASS',checks,negative_contract_cases:negatives.length,
  real_Commander_parse_calls:calls,production_command_boundary:true,synthetic_session_only:true,real_network:0,
  official_CLI_started:false,installed_writes:0})+'\n');
})().catch(error=>{process.stderr.write(String(error.stack)+'\n');process.exitCode=1;});
