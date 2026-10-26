// Entirely synthetic responses. The production fetch and HTTPS gates run first.
import fs from 'node:fs';
const observed=JSON.parse(fs.readFileSync(new URL('./NetEaseSearchRecordsShape.json',import.meta.url)));
const scenario=process.env.ARL_SYNTHETIC_SHARED_CASE;
const cases=['rich_business_frame','bounded_small','bounded_large','formatter_expanded','numeric_expansion','playlist_bounded_pages','provider_body_oversize','business_rejection','resource_missing','bad_result'];
if(!cases.includes(scenario))throw Error('synthetic_case_unknown');
const source=`
import https from 'node:https';
export default async function fetch(url,options) {
 const request=https.request(url,options);request.end();
 const target=new URL(url),scenario=${JSON.stringify(scenario)};
 const created='/openapi/music/basic/playlist/created/get/v2',detail='/openapi/music/basic/playlist/detail/get/v2',
  tracks='/openapi/music/basic/playlist/song/list/get/v3',search='/openapi/music/basic/search/song/get/v2';
 const param=(name,type='string')=>({name,type,in:'query',required:true,default:{unused:'SYNTHETIC'},
  description:'SYNTHETIC-DISPLAY',metadata:{label:'SYNTHETIC-LABEL'},transform:null});
 const method=(name,path,fields)=>({name,path,http_method:'GET',auth_required:true,auth_provider:'netease',
  description:'SYNTHETIC-DISPLAY',extension:{unused:true},metadata:{description:'SYNTHETIC'},preprocess:[],
  fixed_params:{neverSend:'SYNTHETIC-UNUSED-BODY',limit:999},parameters:[...fields,
   {name:'unusedOptional',type:'cover_image_upload',in:'body',required:null,default:'SYNTHETIC-UNUSED'}]});
 let value;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest') {
  const c=method('created',created,[param('limit','integer'),param('offset','integer')]);
  const d=method('detail',detail,[param('playlistId')]);
  const t=method('tracks',tracks,[param('playlistId'),param('limit','integer'),param('offset','integer')]);
  const s=method('song',search,[param('keyword'),param('limit','integer'),param('offset','integer')]);
  t.parameters.push({name:'qualityFlag',type:'integer',in:'query',required:false,default:99});
  s.parameters.push({name:'trialScene',type:'string',in:'query',required:false,default:'SYNTHETIC-UNUSED'});
  if(scenario==='search_wrong_method')s.http_method='POST';
  if(scenario==='search_wrong_auth')s.auth_required=false;
  if(scenario==='detail_wrong_route')t.path='/openapi/music/basic/playlist/song/add';
  if(scenario==='search_unknown_required')s.parameters.at(-2).required=true;
  if(scenario==='detail_dependent_call')t.parameters[0].metadata={dependent_call:{path:'/never',method:'POST'}};
  if(scenario==='search_preprocess')s.preprocess={enabled:true};
  if(scenario==='search_bad_location')s.parameters[0].location='body';
  if(scenario==='search_duplicate')s.parameters.push({...s.parameters[0]});
  if(scenario==='detail_duplicate_command')d.name='tracks';
  // Map key does not override the value's own name, matching the pinned CLI.
  if(scenario==='search_extended')s.parameters=Object.fromEntries(s.parameters.map((p,i)=>[i===0?'providerAlias':p.name,p]));
  if(scenario==='detail_extended')d.fixed_params=null;
  value={notices:['SYNTHETIC-UNUSED-NOTICE'],manifests:{root:{sub_resources:[
   {name:'playlist',path:'playlist'},{name:'search',path:'search'},{name:'unused',path:'unused'}]},
   playlist:{methods:[c,d,t,{name:'create',http_method:'POST',metadata:{dependent_call:true}}]},
   search:{methods:[s]},unused:{methods:[{name:'write',http_method:'POST',path:'/never'}]}}};
 } else {
  const business=JSON.parse(target.searchParams.get('bizContent'));
  const expected=target.pathname===created?{limit:'50',offset:'0'}:
   target.pathname===detail?{playlistId:'1'.repeat(32)}:
   target.pathname===tracks?{playlistId:'1'.repeat(32),limit:'100',offset:scenario==='playlist_bounded_pages'?String(business.offset):'0'}:
   target.pathname===search?{keyword:'Synthetic query',limit:'20',offset:scenario==='rich_business_frame'?String(business.offset):'0'}:null;
  if(!expected||Object.keys(business).sort().join()!==Object.keys(expected).sort().join()||
    !Object.entries(expected).every(([k,v])=>business[k]===v||['limit','offset'].includes(k)&&business[k]===Number(v)))
   throw Error('synthetic_business_mismatch');
  const playlist={id:'1'.repeat(32),name:'Synthetic playlist',trackCount:1};
  const song={id:'2'.repeat(32),name:'Synthetic song',ar:['Synthetic artist'],al:'Synthetic album',visible:true};
  value={code:200,data:target.pathname===created?{recordCount:1,records:[playlist]}:
   target.pathname===detail?{playlist}: {total:1,songs:[song]}};
  if(scenario==='playlist_bounded_pages') {
   const all=Array.from({length:100},(_,i)=>({id:(i+1).toString(16).padStart(32,'0'),name:'A'.repeat(800),ar:['Synthetic artist'],al:'B'.repeat(400)}));
   if(target.pathname===detail)value={code:200,data:{playlist:{...playlist,trackCount:100}}};
   if(target.pathname===tracks){const offset=Number(business.offset);if(!Number.isInteger(offset)||offset<0||offset>100)throw Error('invalid_mock_page');value={code:200,data:{total:100,hasMore:false,songs:all.slice(offset)}};}
  }
  if(target.pathname===search) {
   value=${JSON.stringify(observed)};
   if(scenario==='rich_business_frame') {
    const rows=Array.from({length:20},(_,i)=>({id:(i+1).toString(16).padStart(32,'0'),name:'n'.repeat(800),
     artists:Array.from({length:20},(_,j)=>({id:(j+100).toString(16).padStart(32,'0'),name:'a'.repeat(200)})),
     album:{id:'b'.repeat(32),name:'b'.repeat(400)},duration:240000,originCoverType:1,visible:true,playFlag:true,privateCloudSong:false}));
    const offset=Number(business.offset);if(!Number.isInteger(offset)||offset<0||offset>20)throw Error('invalid_mock_page');
    value={code:200,data:{records:rows.slice(offset),recordCount:20}};
   }
   if(scenario==='bounded_large')for(const row of value.data.records)row.unconsumedDescription='SYNTHETIC-UNCONSUMED-'.repeat(220);
   if(scenario==='formatter_expanded')for(const row of value.data.records)row.unconsumedMetadata=Array.from({length:12000},()=>0);
   if(scenario==='numeric_expansion')value.unconsumedMetadata=Array.from({length:50000},()=>1e20);
   if(scenario==='provider_body_oversize')value.data.records[0].unconsumedDescription='x'.repeat(1048576);
   if(scenario==='resource_missing')value={code:200,subCode:'10007',data:null,message:'SYNTHETIC-PROVIDER-TEXT-MUST-NOT-LEAK'};
   if(scenario==='business_rejection')value={code:403,data:null,message:'SYNTHETIC-PROVIDER-TEXT-MUST-NOT-LEAK'};
   if(scenario==='bad_result')value.data.records[0].name='';
   if(scenario==='search_records_ambiguous')value.data.songs=[{...song,id:'f'.repeat(32)}];
   if(scenario==='search_records_wrong_type')value.data.records=null;
  }
 }
 const bytes=Buffer.from(scenario==='numeric_expansion'?JSON.stringify(value).replaceAll('100000000000000000000','1e20'):JSON.stringify(value));
 return {ok:true,status:200,arrayBuffer:async()=>bytes};
}
`;
export async function load(url,context,nextLoad) {
 if(url.endsWith('/NetEase/node_modules/node-fetch/src/index.js'))return {format:'module',shortCircuit:true,source};
 return nextLoad(url,context);
}
