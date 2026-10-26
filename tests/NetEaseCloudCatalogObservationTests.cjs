'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const srcPath=path.resolve(process.argv[2]||'integrations/service_runtime/netease_bridge.cjs');
const src=fs.readFileSync(srcPath,'utf8'),setup=src.slice(0,src.lastIndexOf('\ntry {\n  const request=readRequest();'));
const api=new Function('require','__dirname',setup+'\nreturn {cloudCatalogObservation,observeCloudCatalog,FiniteDiagnostics,set(c,d){readContext=c;diagnostic=d;},secret(v){privatePatterns.add(v);},clear(){privatePatterns.clear();}};')(require,path.dirname(srcPath));
const route='/openapi/music/basic/private/cloud/song/list/get';
const fixture=()=>({manifests:{root:{sub_resources:[{name:'cloudAsset',path:'fixture/cloud'}]},
 'fixture/cloud':{methods:[{name:'songs',path:route,http_method:'GET',auth_required:true,parameters:[
 {name:'offset',type:'integer',in:'query',required:true},{name:'limit',type:'integer',in:'query',required:true}]}]}}});
let tests=0;const check=fn=>{fn();tests++;};
check(()=>{const v=api.cloudCatalogObservation(fixture());assert.equal(v.group,'cloudAsset');assert.equal(v.command,'songs');assert.equal(v.offset_type,'integer');assert.equal(v.parameter_count,'2');});
check(()=>{const f=fixture();f.manifests['fixture/cloud'].methods=[];assert.deepEqual(api.cloudCatalogObservation(f),{state:'missing'});});
check(()=>{const f=fixture();f.manifests['fixture/cloud'].methods.push(f.manifests['fixture/cloud'].methods[0]);assert.deepEqual(api.cloudCatalogObservation(f),{state:'ambiguous'});});
check(()=>{const f=fixture();f.manifests['fixture/cloud'].methods[0].parameters.push({name:'offset'});assert.deepEqual(api.cloudCatalogObservation(f),{state:'invalid'});});
check(()=>{const f=fixture();f.manifests['fixture/cloud'].methods[0].parameters.push({name:'PRIVATE_VALUE',required:true});const v=api.cloudCatalogObservation(f);assert.equal(v.extra_required_parameters,'1');assert.ok(!JSON.stringify(v).includes('PRIVATE_VALUE'));});
check(()=>{const f=fixture();f.manifests['fixture/cloud'].methods[0].auth_required=false;assert.equal(api.cloudCatalogObservation(f).auth_required,'false');});
check(()=>{const f=fixture();f.manifests.root.sub_resources[0].name='https://private.invalid';assert.deepEqual(api.cloudCatalogObservation(f),{state:'invalid'});});
check(()=>{const f=fixture();f.manifests['fixture/cloud'].methods[0].parameters[0].location='body';assert.equal(api.cloudCatalogObservation(f).offset_location,'conflict');});
check(()=>{const f=fixture();f.manifests['fixture/cloud'].methods[0].metadata={secret:'PRIVATE_VALUE'};assert.ok(!JSON.stringify(api.cloudCatalogObservation(f)).includes('PRIVATE_VALUE'));});
check(()=>{const events=[],d=new api.FiniteDiagnostics('00000000-0000-0000-0000-000000000001',x=>events.push(x));api.set({operation:'search',isWrite:false},d);api.observeCloudCatalog(fixture());api.observeCloudCatalog(fixture());assert.equal(events.length,1);assert.equal(events[0].cloud_catalog.command,'songs');assert.equal(d.failed,false);assert.equal(d.phase,'initialize');});
check(()=>{for(const c of [{operation:'playlist_append',isWrite:true},{operation:'tracks',isWrite:false}]){const events=[];api.set(c,{record(...v){events.push(v);}});api.observeCloudCatalog(fixture());assert.equal(events.length,0);}});
check(()=>{const events=[];api.secret('cloudAsset');api.set({operation:'search',isWrite:false},{record(...v){events.push(v);}});api.observeCloudCatalog(fixture());assert.equal(events.length,0);api.clear();});
check(()=>{const events=[],d={phase:'provider',last:'prior',lastValues:{code:200},record(){throw Error('diagnostic failure');}};api.set({operation:'search',isWrite:false},d);assert.doesNotThrow(()=>api.observeCloudCatalog(fixture()));assert.equal(d.last,'prior');assert.deepEqual(d.lastValues,{code:200});});
console.log(JSON.stringify({status:'PASS',tests,provider_calls:0,credential_access:0,cloud_reads:0,fixture_command_is_synthetic:true}));
