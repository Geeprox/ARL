// Synthetic official-CLI consumer evidence; never contact a real provider.
const scenario=process.env.ARL_SYNTHETIC_WRITE_CASE;
if(!/^(create|append)_(display|fixed_null|fixed_same|fixed_extra|fixed_override|preprocess|wrong_route|unknown_param|wrong_auth|get)$/.test(scenario||''))throw Error('unknown_fixture');
const source=`
import https from 'node:https';
export default async function fetch(url,options) {
 const request=https.request(url,options);request.end();
 const target=new URL(url),scenario=${JSON.stringify(scenario)};
 const create='/openapi/music/playlist/create',append='/openapi/music/playlist/song/add';
 const param=name=>({name,type:'string',in:'body',required:true,description:'SYNTHETIC',
   title:'SYNTHETIC',metadata:{label:'SYNTHETIC'},default:'UNUSED-OWNER-OVERRIDES',transform:null});
 const make=(name,path,fields)=>({name,path,http_method:'POST',auth_required:true,auth_provider:'netease',
   description:'SYNTHETIC',title:'SYNTHETIC',metadata:{description:'SYNTHETIC',examples:[]},preprocess:[],
   parameters:fields.map(param),fixed_params:{}});
 let value;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest') {
  const c=make('create',create,['playlistName']),a=make('add',append,['playlistId','songIds']);
  if(scenario==='append_display')a.parameters=Object.fromEntries(a.parameters.map(p=>[p.name,p]));
  if(scenario==='create_fixed_null')c.fixed_params=null;
  if(scenario==='create_fixed_same')c.fixed_params={playlistName:'Synthetic playlist'};
  if(scenario==='append_fixed_same')a.fixed_params={playlistId:'1'.repeat(32),songIds:'2'.repeat(32)};
  if(scenario==='create_fixed_extra')c.fixed_params={privacy:'1'};
  if(scenario==='append_fixed_override')a.fixed_params={songIds:'3'.repeat(32)};
  if(scenario==='create_preprocess')c.preprocess={call:'/never'};
  if(scenario==='append_wrong_route')a.path='/openapi/music/playlist/delete';
  if(scenario==='create_unknown_param')c.parameters.push({...param('privacy'),required:false});
  if(scenario==='append_wrong_auth')a.auth_required=false;
  if(scenario==='create_get')c.http_method='GET';
  value={notices:[],manifests:{root:{sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[c,a]}}};
 } else {
  if(options.method!=='POST'||target.search!=='')throw Error('synthetic_post_required');
  const signed=JSON.parse(options.body),business=JSON.parse(signed.bizContent);
  const expected=target.pathname===create?{playlistName:'Synthetic playlist'}:
   target.pathname===append?{playlistId:'1'.repeat(32),songIds:'2'.repeat(32)}:null;
  if(!expected||Object.keys(business).sort().join()!==Object.keys(expected).sort().join()||
    !Object.entries(expected).every(([k,v])=>business[k]===v))throw Error('synthetic_target_mismatch');
  if(!signed.accessToken||!signed.sign)throw Error('synthetic_signed_session_required');
  const intent=Object.entries(options.headers).find(([k])=>k.toLowerCase()==='x-user-input')?.[1];
  if(!intent)throw Error('synthetic_user_intent_required');
  value={code:200,data:{id:'1'.repeat(32),name:'Synthetic playlist'}};
 }
 const bytes=Buffer.from(JSON.stringify(value));return {ok:true,status:200,arrayBuffer:async()=>bytes};
}
`;
export async function load(url,context,nextLoad) {
 if(url.endsWith('/NetEase/node_modules/node-fetch/src/index.js'))return {format:'module',shortCircuit:true,source};
 return nextLoad(url,context);
}
