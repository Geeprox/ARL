// Synthetic only. Production HTTPS/bizContent guards and the pinned CLI still run.
const scenario=process.env.ARL_SYNTHETIC_TERMINAL_CASE;
if(!['empty_zero','continuation_end','count_conflict','empty_count_conflict','missing_null','closing_drift'].includes(scenario))throw Error('unknown_fixture');
const source=`
import https from 'node:https';
let details=0;
export default async function fetch(url,options) {
 const request=https.request(url,options);request.end();
 const target=new URL(url),scenario=${JSON.stringify(scenario)};
 const detail='/openapi/music/basic/playlist/detail/get/v2',tracks='/openapi/music/basic/playlist/song/list/get/v3';
 const method=(name,path,fields)=>({name,path,http_method:'GET',auth_required:true,parameters:fields.map(name=>({name,type:['offset','limit'].includes(name)?'integer':'string',in:'query',required:true}))});
 let value;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest')value={manifests:{root:{sub_resources:[{name:'playlist',path:'playlist'}]},playlist:{methods:[method('detail',detail,['playlistId']),method('tracks',tracks,['playlistId','limit','offset'])]}}};
 else {
  const biz=JSON.parse(target.searchParams.get('bizContent'));
  if(biz.playlistId!=='1'.repeat(32))throw Error('wrong_target');
  if(target.pathname===detail){details++;const count=scenario==='empty_zero'?0:['count_conflict','empty_count_conflict'].includes(scenario)?2:scenario==='closing_drift'&&details>1?2:1;
   value=scenario==='missing_null'?{code:200,subCode:'10007',data:null,message:'SYNTHETIC MISSING'}:{code:200,data:{id:'1'.repeat(32),name:'Synthetic playlist',trackCount:count}};
  }else if(target.pathname===tracks){
   const offset=Number(biz.offset);if(Number(biz.limit)!==100||!Number.isSafeInteger(offset)||offset<0||offset>1)throw Error('wrong_page');
   value=scenario==='empty_zero'||scenario==='empty_count_conflict'||offset===1?{code:200,subCode:'10007',message:'SYNTHETIC END',data:[]}:
    {code:200,subCode:'200',data:[{id:'2'.repeat(32),name:'Synthetic song',ar:['Synthetic artist'],al:'Synthetic album'}]};
  }else throw Error('wrong_route');
 }
 const bytes=Buffer.from(JSON.stringify(value));return {ok:true,status:200,arrayBuffer:async()=>bytes};
}
`;
export async function load(url,context,nextLoad){if(url.endsWith('/NetEase/node_modules/node-fetch/src/index.js'))return {format:'module',shortCircuit:true,source};return nextLoad(url,context);}
