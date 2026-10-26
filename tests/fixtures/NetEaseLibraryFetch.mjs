import https from 'node:https';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const cases=JSON.parse(fs.readFileSync(process.env.ARL_LIBRARY_SPECS,'utf8'));
const op=process.env.ARL_LIBRARY_OPERATION,scenario=process.env.ARL_LIBRARY_SCENARIO;
const args=JSON.parse(process.env.ARL_LIBRARY_ARGUMENTS),spec=cases[op];
export default async function fetch(url,options) {
 const request=https.request(url,options);request.end();
 const target=new URL(url);let value;
 if(target.pathname==='/openapi/v1/ncm/cli/manifest') {
  let method=structuredClone(spec.method);
  if(scenario==='wrong_method')method.http_method=method.http_method==='POST'?'GET':'POST';
  if(scenario==='wrong_path')method.path='/openapi/music/basic/comment/get/v2';
  if(scenario==='extra_required')method.parameters.push({name:'unknown',type:'string',in:'query',required:true});
  if(scenario==='wrong_auth')method.auth_required=false;
  method.parameters.push({name:'unusedOptional',type:'string',in:'query',required:false,default:'NEVER_SEND'});
  value={notices:[],manifests:{root:{methods:[],sub_resources:[{name:spec.group,path:spec.group}]},[spec.group]:{methods:[method],sub_resources:[]}}};
 } else {
  assert.equal(target.pathname,spec.method.path);
  assert.equal(options.method,spec.method.http_method);
  const signed=options.method==='POST'?JSON.parse(options.body):Object.fromEntries(target.searchParams);
  const actual=JSON.parse(signed.bizContent);
  assert.deepEqual(Object.keys(actual).sort(),Object.keys(args).sort());
  for(const [k,v] of Object.entries(args))assert.ok(actual[k]===v||['limit','offset','startTime','endTime'].includes(k)&&actual[k]===Number(v)||['descFlag','qualityFlag'].includes(k)&&actual[k]===(v==='true'));
  if(scenario==='artist_bad_start'||scenario==='artist_secret_message') {
   const b=Buffer.from(JSON.stringify({code:400,message:scenario==='artist_bad_start'?'发布开始时间格式错误':'SYNTHETIC-LIBRARY-SESSION',data:null}));
   return {ok:true,status:200,arrayBuffer:async()=>b};
  }
  if(scenario==='contradictory_count') {
   const b=Buffer.from(JSON.stringify({code:200,data:{recordCount:0,records:[{id:'1'.repeat(32),name:'Synthetic collection item'}],integer:JSON.rawJSON('9007199254740993')}}));
   return {ok:true,status:200,arrayBuffer:async()=>b};
  }
  if(scenario==='http403') {
   const b=Buffer.from(JSON.stringify({code:403,data:null,message:'SYNTHETIC_DENIED'}));
   return {ok:false,status:403,arrayBuffer:async()=>b};
  }
  value={code:200,data:{records:[{id:'1'.repeat(32),name:'Synthetic item'},{id:'1'.repeat(32),name:'Same ID retained'}],integer:JSON.rawJSON('9007199254740993'),lyrics:'SYNTHETIC_LINE',empty:[],nullable:null,flag:false,accessToken:'SYNTHETIC-RESPONSE-SECRET',padding:scenario==='oversize'?'Z'.repeat(280000):'TAIL'},future:{version:1}};
 }
 const b=Buffer.from(JSON.stringify(value));return {ok:true,status:200,arrayBuffer:async()=>b};
}
