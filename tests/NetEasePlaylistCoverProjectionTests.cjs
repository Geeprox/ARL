'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const source=fs.readFileSync(process.argv[2]||path.resolve(__dirname,'../integrations/service_runtime/netease_bridge.cjs'),'utf8');
const prefix=source.slice(0,source.indexOf('\ntry {\n  const request=readRequest();'));
const api=new Function('require','__dirname',prefix+'return {rememberProviderRecords,projectItem,providerRecord,projectWriteManifestReply,validateCoverBusiness,coverResult,coverNOSFetch,context:v=>{readContext=v;}};')(require,path.resolve(__dirname,'../integrations/service_runtime'));
const id='1'.repeat(32),url='http://p2.music.126.net/matched/109951165474121408.jpg';
api.context({isWrite:false,operation:'playlist_detail'});
const projected=api.projectItem({encryptedId:id,name:'Synthetic album',trackCount:10,coverImgUrl:url,
 unknownExtension:{preserved:[null,4,'value']},accessToken:'NEVER-PUBLIC',nested:{'x-nos-token':'NEVER-PUBLIC',kept:true}},'playlist');
assert.equal(projected.provider_record.fields.coverImgUrl,url);
assert.deepEqual(projected.provider_record.fields.unknownExtension.preserved,[null,4,'value']);
assert.equal(projected.provider_record.fields.nested.kept,true);assert(!JSON.stringify(projected).includes('NEVER-PUBLIC'));
assert.deepEqual(projected.provider_record.omitted_authentication_fields,['accesstoken','token']);
assert.equal(api.projectItem({encryptedId:id,name:'null cover',coverImgUrl:null},'playlist').provider_record.fields.coverImgUrl,null);
assert(!Object.hasOwn(api.projectItem({encryptedId:id,name:'absent cover'},'playlist').provider_record.fields,'coverImgUrl'));
api.rememberProviderRecords(Buffer.from('{"code":200,"data":{"encryptedId":"'+id+'","name":"lossless","coverImgId":1099511650000000123}}'));
const lossless=api.projectItem({encryptedId:id,name:'lossless',coverImgId:1099511650000000000},'playlist');
assert(JSON.stringify(lossless.provider_record).includes('1099511650000000123'));
const cover={resourceID:'1099511650000000123',uploadComplete:true,receipts:[],response:{fields:{code:200,data:{nullValue:null,detail:'full'}},omitted_authentication_fields:[]}};
api.context({isWrite:true,operation:'playlist_cover',arguments:{playlist_id:id},cover});
const picture={originId:cover.resourceID,format:'jpg',width:1000,height:1000},business={playlistId:id,picIds:JSON.stringify([picture])};
api.validateCoverBusiness('/openapi/music/basic/playlist/cover/update',business);
assert.throws(()=>api.validateCoverBusiness('/openapi/music/basic/playlist/cover/update',{...business,playlistId:'2'.repeat(32)}));
assert.throws(()=>api.validateCoverBusiness('/openapi/music/basic/playlist/cover/update',{...business,picIds:JSON.stringify([{...picture,originId:'7'}])}));
assert.throws(()=>api.validateCoverBusiness('/openapi/music/basic/playlist/cover/update',{...business,picIds:JSON.stringify([picture,picture])}));
assert.equal(api.coverResult('submitted').provider_response_complete,true);
cover.response.fields.data.detail='x'.repeat(190000);
assert.equal(api.coverResult('submitted').provider_response_complete,false);assert.equal(api.coverResult('submitted').provider_response,null);
const method={name:'updateCover',path:'/openapi/music/basic/playlist/cover/update',http_method:'POST',auth_required:true,
 parameters:[{name:'playlistId',type:'string',in:'query',required:true},{name:'picIds',type:'imgs_file_upload',in:'query',required:true}]};
const manifest={manifests:{root:{sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[method]}}};
assert.equal(api.projectWriteManifestReply(manifest).manifests.playlist.methods[0].parameters[1].type,'imgs_file_upload');
method.path='/openapi/music/basic/playlist/delete';assert.throws(()=>api.projectWriteManifestReply(manifest));
(async()=>{for(const url of ['http://wanproxy.127.net/lbs','https://evil.example/yyimgs/key','https://wanproxy-web.127.net/other/key'])
 await assert.rejects(api.coverNOSFetch(url,{method:'POST',headers:{},body:Buffer.from('x')},'not-used'));
 process.stdout.write(JSON.stringify({status:'PASS',raw_playlist_cover:true,null_vs_absent:true,auth_removed:true,resource_binding:true,explicit_large_reply:true,real_network:0})+'\n');
})().catch(e=>{process.stderr.write(String(e));process.exitCode=1;});
