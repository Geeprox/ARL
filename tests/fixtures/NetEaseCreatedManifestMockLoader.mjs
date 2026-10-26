// Synthetic transport only. Production HTTPS admission still runs first.
const scenario=process.env.ARL_SYNTHETIC_CREATED_CASE||'valid';
if(!['valid','multi','unknown','latent','tail','falsy','map','map_fault'].includes(scenario))throw Error('synthetic_case_unknown');
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
  if(['multi','unknown','latent'].includes(scenario)) {
   method.auth_provider=false;Object.assign(method.parameters[0],{in:false,location:'query',metadata:{dependent_call:true},transform:{active:true},default:{},required:null});
   if(scenario!=='latent'){method.fixed_params=null;method.http_method='POST';}
   if(scenario==='unknown'){method.auth_provider='SYNTHETIC_UNKNOWN';method.parameters[0].in='SYNTHETIC_UNKNOWN';}
  } else if(scenario==='tail') {
   method.parameters=Array.from({length:6},(_,i)=>({name:i===5?'SYNTHETIC_UNKNOWN':i%2?'offset':'limit',in:'query',type:'integer'}));
   method.parameters[5].metadata={dependent_call:true};
  } else if(['map','map_fault'].includes(scenario)) {
   method.parameters={limit:{type:'integer',in:'query'},offset:{type:'integer',in:'query'}};
   if(scenario==='map_fault')Object.assign(method.parameters.limit,{metadata:{dependent_call:true},transform:{active:true},default:{},required:null});
  } else if(scenario==='falsy') {
   method.auth_provider=0;Object.assign(method.parameters[0],{in:false,location:'query'});
  }
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
