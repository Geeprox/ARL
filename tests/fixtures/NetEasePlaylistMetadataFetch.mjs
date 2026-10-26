import https from 'node:https';
import assert from 'node:assert/strict';
const op=process.env.ARL_METADATA_OP,scenario=process.env.ARL_METADATA_CASE,args=JSON.parse(process.env.ARL_METADATA_ARGS);
const rename=op==='playlist_update_name',route='/openapi/music/basic/playlist/'+(rename?'name':'desc')+'/update';
export default async function fetch(url,options) {
 const request=https.request(url,options);request.end();
 const target=new URL(url);let value;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest') {
  const method={name:rename?'updateName':'updateDesc',path:route,http_method:'POST',auth_required:true,auth_provider:'netease',
   parameters:['playlistId',rename?'name':'desc'].map(name=>({name,type:'string',in:'query',required:true})),
   fixed_params:{unrelated:'NEVER_SEND'},preprocess:{unused:true}};
  if(scenario==='wrong_method')method.http_method='GET';
  if(scenario==='wrong_path')method.path='/openapi/music/basic/playlist/song/batch/delete';
  if(scenario==='wrong_auth')method.auth_required=false;
  if(scenario==='extra_required')method.parameters.push({name:'privacy',type:'string',in:'query',required:true});
  value={notices:[],manifests:{root:{methods:[],sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[method],sub_resources:[]}}};
 } else {
  assert.equal(target.pathname,route);assert.equal(options.method,'POST');assert.equal(target.search,'');
  const signed=JSON.parse(options.body),actual=JSON.parse(signed.bizContent);
  assert.deepEqual(actual,{playlistId:args.playlist_id,[rename?'name':'desc']:args.value});
  assert.ok(signed.sign&&signed.accessToken);
  if(scenario==='lost_after_effect')throw Error('SYNTHETIC_CONNECTION_LOST');
  value=scenario==='provider400'?{code:400,message:'SYNTHETIC_REJECTED',data:null}:{code:200,data:null};
 }
 const bytes=Buffer.from(JSON.stringify(value));return {ok:true,status:200,arrayBuffer:async()=>bytes};
}
