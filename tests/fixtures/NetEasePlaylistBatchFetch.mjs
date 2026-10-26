import https from 'node:https';
import assert from 'node:assert/strict';
const spec=JSON.parse(process.env.ARL_BATCH_SPEC),scenario=process.env.ARL_METADATA_CASE,args=JSON.parse(process.env.ARL_METADATA_ARGS);
export default async function fetch(url,options) {
 const request=https.request(url,options);request.end();const target=new URL(url);let value;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest') {
  const method=structuredClone(spec);
  if(scenario==='wrong_method')method.http_method='GET';
  if(scenario==='wrong_path')method.path='/openapi/music/basic/playlist/delete';
  if(scenario==='wrong_auth')method.auth_required=false;
  if(scenario==='wrong_location')method.parameters[0].in=method.parameters[0].in==='query'?'body':'query';
  if(scenario==='wrong_type')method.parameters[1].type=method.parameters[1].type==='string'?'array':'string';
  if(scenario==='extra_required')method.parameters.push({name:'extra',type:'string',in:'query',required:true});
  value={notices:[],manifests:{root:{methods:[],sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[method],sub_resources:[]}}};
 } else {
  assert.equal(target.pathname,spec.path);assert.equal(options.method,'POST');assert.equal(target.search,'');
  const signed=JSON.parse(options.body),actual=JSON.parse(signed.bizContent),tags=spec.name==='updateTags';
  assert.deepEqual(actual,{playlistId:args.playlist_id,[tags?'tags':spec.name==='reorder'?'trackIds':'songIdList']:tags?args.tags:JSON.parse(args.song_ids)});
  assert.ok(signed.sign&&signed.accessToken);
  if(scenario==='lost_after_effect')throw Error('SYNTHETIC_CONNECTION_LOST');
  value=scenario==='provider400'?{code:400,message:'SYNTHETIC_REJECTED',data:null}:{code:200,data:null};
 }
 const bytes=Buffer.from(JSON.stringify(value));return {ok:true,status:200,arrayBuffer:async()=>bytes};
}
