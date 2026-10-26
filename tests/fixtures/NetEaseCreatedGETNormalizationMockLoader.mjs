// Synthetic transport only. Production HTTPS admission still runs first.
const scenario=process.env.ARL_SYNTHETIC_CREATED_CASE||'valid';
if(!['fixed_null','fixed_body_map','wrong_method','wrong_auth','wrong_route'].includes(scenario))throw Error('synthetic_case_unknown');
const fakeFetch = `
import https from 'node:https';
export default async function fetch(url, options) {
 const request=https.request(url,options);request.end();
 const target=new URL(url);let value;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest') {
  value={notices:['SYNTHETIC-DISPLAY-NOTICE'],manifests:{
   root:{version:'fixture-v1',sub_resources:[{name:'playlist',path:'playlist'}]},
   playlist:{version:'fixture-v1',methods:[{name:'created',description:'Synthetic display extension',
    extension:'SYNTHETIC-DISPLAY-ONLY',metadata:null,preprocess:[],http_method:'GET',auth_required:true,
    path:'/openapi/music/basic/playlist/created/get/v2',parameters:[
     {name:'limit',in:'query',type:'integer',required:true,default:999},
     {name:'offset',in:'query',type:'integer',required:true,default:'poison'}]}]}
  }};
  const method=value.manifests.playlist.methods[0],scenario=${JSON.stringify(scenario)};
  method.fixed_params=null;
  if(scenario==='fixed_body_map') {
   method.fixed_params={neverSend:'SYNTHETIC_UNUSED_BODY',limit:999,offset:999};
   method.parameters={limit:{type:'integer',in:'query',required:true},offset:{type:'integer',in:'query',required:true}};
  }
  if(scenario==='wrong_method')method.http_method='POST';
  if(scenario==='wrong_auth')method.auth_required=false;
  if(scenario==='wrong_route')method.path='/openapi/music/basic/playlist/create';
 } else if(target.pathname==='/openapi/music/basic/playlist/created/get/v2') {
  value={code:200,data:{recordCount:1,records:[{id:'1'.repeat(32),name:'Synthetic playlist',trackCount:0}]}};
 } else throw new Error('synthetic_unreviewed_route');
 const bytes=Buffer.from(JSON.stringify(value));
 return {ok:true,status:200,arrayBuffer:async()=>bytes};
}
`;
export async function load(url, context, nextLoad) {
 if(url.endsWith('/NetEase/node_modules/node-fetch/src/index.js'))return {format:'module',shortCircuit:true,source:fakeFetch};
 return nextLoad(url,context);
}
