// Pinned official CLI, synthetic catalog and provider; no live network.
const scenario=process.env.ARL_SYNTHETIC_ARRAY_CASE;
const cases=['append_array_body','append_array_map','append_array_location','append_array_mixed',
 'append_scalar_body','append_scalar_get','create_scalar_get','append_array_query','append_playlist_array',
 'append_array_query_get','append_array_get_body','create_array','append_conflict_location','append_required_unknown','append_map_mismatch',
 'append_missing_song','append_tamper_extra','append_tamper_wrong','append_tamper_scalar','append_tamper_number',
 'append_observed','append_provider_rejected','append_observed_noise','append_legacy_name','append_wrong_route','append_query_wrong_song','append_query_extra_songs'];
if(!cases.includes(scenario))throw Error('unknown_fixture');
const source=`
import https from 'node:https';
export default async function fetch(url,options) {
 const request=https.request(url,options);request.end();
 const target=new URL(url),scenario=${JSON.stringify(scenario)};
 const create='/openapi/music/playlist/create',append='/openapi/music/basic/playlist/song/batch/like';
 const param=(name,type='string')=>({name,type,in:'body',required:true,description:'SYNTHETIC',
   metadata:{label:'SYNTHETIC'},default:['3'.repeat(32)],items:{type:'string'}});
 const make=(name,path,fields)=>({name,path,http_method:'POST',auth_required:true,auth_provider:'netease',
   parameters:fields, fixed_params:{songIdList:['3'.repeat(32)]},preprocess:[]});
 let value;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest') {
  const c=make('create',create,[param('playlistName')]);
  const a=make('add',append,[param('playlistId'),param('songIdList',scenario.startsWith('append_scalar_')?'string':'array')]);
  // Layout/name/type/location/route are from the authenticated 2026-10-10
  // public manifest observation; IDs/session/signing material remain synthetic.
  const observed=['append_observed','append_provider_rejected','append_observed_noise','append_legacy_name','append_wrong_route','append_query_wrong_song','append_query_extra_songs'].includes(scenario);
  if(observed) {
   a.parameters=[{name:'playlistId',type:'string',in:'query',required:true},
     {name:'songIdList',type:'array',in:'query',required:true}];
   a.fixed_params=null;delete a.preprocess;delete a.auth_provider;
   if(scenario==='append_observed_noise') {
    a.parameters.push({name:'unusedDisplayOption',type:'string',in:'query',required:false,default:'unused'});
    a.metadata={ignored:'display only'};a.parameters[1].description='display only';
   }
   if(scenario==='append_legacy_name')a.parameters[1].name='songIds';
   if(scenario==='append_wrong_route')a.path=append+'/unlike';
  }
  if(scenario==='append_array_map')a.parameters=Object.fromEntries(a.parameters.map(p=>{const {name,...v}=p;return [name,v];}));
  if(scenario==='append_array_location')a.parameters.forEach(p=>{p.location=p.in;delete p.in;});
  if(scenario==='append_array_mixed')a.parameters[0].in='query';
  if(scenario==='append_scalar_get'||scenario==='create_scalar_get') {
   const m=scenario.startsWith('create')?c:a;m.http_method='GET';m.parameters.forEach(p=>p.in='query');
  }
  if(scenario==='append_array_query')a.parameters[1].in='query';
  if(scenario==='append_array_query_get'){a.http_method='GET';a.parameters.forEach(p=>p.in='query');}
  if(scenario==='append_array_get_body'){a.http_method='GET';a.parameters[0].in='query';}
  if(scenario==='append_playlist_array')a.parameters[0].type='array';
  if(scenario==='create_array')c.parameters[0].type='array';
  if(scenario==='append_conflict_location')a.parameters[1].location='query';
  if(scenario==='append_required_unknown')a.parameters.push(param('unreviewed'));
  if(scenario==='append_map_mismatch')a.parameters={playlistId:a.parameters[0],songIdList:{...a.parameters[1],name:'other'}};
  if(scenario==='append_missing_song')a.parameters.pop();
  value={notices:[],manifests:{root:{sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[c,a]}}};
 } else {
  const expectedMethod=scenario.endsWith('_get')?'GET':'POST';
  if(options.method!==expectedMethod)throw Error('synthetic_declared_method_required');
  if(expectedMethod==='POST'&&target.search!==''||expectedMethod==='GET'&&options.body!==undefined)throw Error('synthetic_transport_mismatch');
  const signed=expectedMethod==='POST'?JSON.parse(options.body):Object.fromEntries(target.searchParams),business=JSON.parse(signed.bizContent);
  const expected=target.pathname===create?{playlistName:'Synthetic playlist'}:target.pathname===append?
   {playlistId:'1'.repeat(32),songIdList:scenario.startsWith('append_scalar_')||['append_array_query_get'].includes(scenario)?'2'.repeat(32):['2'.repeat(32)]}:null;
  if(!expected||Object.keys(business).sort().join()!==Object.keys(expected).sort().join()||
    !Object.entries(expected).every(([k,v])=>JSON.stringify(business[k])===JSON.stringify(v)))throw Error('synthetic_target_mismatch');
  if(!signed.accessToken||!signed.sign)throw Error('synthetic_signed_session_required');
  const intent=Object.entries(options.headers).find(([k])=>k.toLowerCase()==='x-user-input')?.[1];
  if(!intent)throw Error('synthetic_user_intent_required');
  value=scenario==='append_provider_rejected'
   ?{code:400,message:'songIdList: expected JSON array',msg:'歌曲权限校验失败'}
   :{code:200,data:{id:'1'.repeat(32),name:'Synthetic playlist'}};
 }
 const bytes=Buffer.from(JSON.stringify(value));return {ok:true,status:200,arrayBuffer:async()=>bytes};
}
`;
export async function load(url,context,nextLoad) {
 if(url.endsWith('/NetEase/node_modules/node-fetch/src/index.js'))return {format:'module',shortCircuit:true,source};
 return nextLoad(url,context);
}
